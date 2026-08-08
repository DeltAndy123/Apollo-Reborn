#import "settings/ApolloOpenInAppViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloLinkCompanionViewController.h"

// This screen gathers every "open links in an app" preference in one place:
// Reborn's own per-service deep-link toggles (Bluesky/GitHub/Steam), plus
// mirrors of Apollo's three NATIVE rows — "Open Videos in YouTube App", the
// "Open Links in" browser picker and the "Open Tweets in" picker — which
// read/write Apollo's own defaults keys and are hidden from Apollo's General
// settings (the gather-and-hide registration lives in
// ApolloSettingsNativeInjections.xm). The mirrored pickers reproduce the native
// option lists faithfully, including their installed-app filtering — see
// ApolloOpenInAppBrowserOptions() and ApolloOpenInAppTweetOptions().

// The browsers Apollo's native "Open Links in" picker can offer, in the
// native menu's order. Tokens + labels were recovered by driving the native
// picker in the sim (with canOpenURL faked YES for every browser) and reading
// back the persisted UDKeyNativeOpenLinksIn value after each pick. The first
// two entries have no probe scheme: they're always offered. Every probe scheme
// is declared in Apollo's LSApplicationQueriesSchemes, so canOpenURL answers
// honestly instead of auto-NO.
static NSArray<NSArray<NSString *> *> *ApolloOpenInAppBrowserTable(void) {
    // @[label, token, probe scheme ("" = always shown)]
    return @[
        @[@"In-App Safari", @"in-app-safari",   @""],
        @[@"Safari",        @"external-safari", @""],
        @[@"Chrome",        @"chrome",          @"googlechromes"],
        @[@"Firefox",       @"firefox",         @"firefox"],
        @[@"Firefox Focus", @"firefox-focus",   @"firefox-focus"],
        @[@"Edge",          @"edge",            @"microsoft-edge-https"],
        @[@"Dolphin",       @"dolphin",         @"dolphin"],
        @[@"Brave",         @"brave",           @"brave"],
        @[@"DuckDuckGo",    @"duckduckgo",      @"ddgQuickLink"],
        @[@"iCab Mobile",   @"icab",            @"x-icabmobile"],
    ];
}

static NSString *ApolloOpenInAppCurrentBrowserToken(void) {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNativeOpenLinksIn];
    return token.length > 0 ? token : @"in-app-safari"; // missing key = Apollo's in-app default
}

// The rows offered by the picker right now: the two Safari modes always, a
// third-party browser only when installed — matching the native picker — or
// when it's already the persisted choice (so a value restored from a backup
// stays visible and re-selectable instead of silently vanishing).
static NSArray<NSArray<NSString *> *> *ApolloOpenInAppBrowserOptions(void) {
    NSString *current = ApolloOpenInAppCurrentBrowserToken();
    NSMutableArray<NSArray<NSString *> *> *options = [NSMutableArray array];
    for (NSArray<NSString *> *entry in ApolloOpenInAppBrowserTable()) {
        NSString *probeScheme = entry[2];
        BOOL offered = probeScheme.length == 0 || [entry[1] isEqualToString:current];
        if (!offered) {
            NSURL *probe = [NSURL URLWithString:[probeScheme stringByAppendingString:@"://"]];
            offered = probe && [[UIApplication sharedApplication] canOpenURL:probe];
        }
        if (offered) [options addObject:entry];
    }
    return options;
}

static NSString *ApolloOpenInAppBrowserLabelForToken(NSString *token) {
    for (NSArray<NSString *> *entry in ApolloOpenInAppBrowserTable()) {
        if ([entry[1] isEqualToString:token]) return entry[0];
    }
    return token; // future/unknown token: show it raw rather than mislabeling it
}

// The clients Apollo's native "Open Tweets in" picker offers, in its order.
// An empty probe scheme means always offered. Every probe scheme is in
// Apollo's LSApplicationQueriesSchemes, so canOpenURL answers honestly.
// NOTE Spring's token is "spring" but its URL scheme is "spring2".
static NSArray<NSArray<NSString *> *> *ApolloOpenInAppTweetClientTable(void) {
    // @[label, token, probe scheme ("" = always shown)]
    return @[
        @[@"In-App Safari", @"inAppSafari",     @""],
        @[@"Safari",        @"externalBrowser", @""],
        @[@"Twitter",       @"twitter",         @"twitter"],
        @[@"Twitterrific",  @"twitterrific",    @"twitterrific"],
        @[@"Tweetbot",      @"tweetbot",        @"tweetbot"],
        @[@"Spring",        @"spring",          @"spring2"],
        @[@"Aviary",        @"aviary",          @"aviary"],
    ];
}

static BOOL ApolloOpenInAppTweetClientInstalled(NSString *probeScheme) {
    if (probeScheme.length == 0) return YES;
    NSURL *probe = [NSURL URLWithString:[probeScheme stringByAppendingString:@"://"]];
    return probe && [[UIApplication sharedApplication] canOpenURL:probe];
}

// The effective tweet destination. Unlike the browser mirror, an
// uninstalled-client token is not kept: Apollo rewrites it to inAppSafari as
// soon as it notices, so resolve it (and missing/unknown tokens) the same way.
static NSString *ApolloOpenInAppCurrentTweetToken(void) {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNativeOpenTwitterLinksIn];
    if (token.length == 0) return @"inAppSafari"; // missing key = Apollo's default
    for (NSArray<NSString *> *entry in ApolloOpenInAppTweetClientTable()) {
        if (![entry[1] isEqualToString:token]) continue;
        return ApolloOpenInAppTweetClientInstalled(entry[2]) ? token : @"inAppSafari";
    }
    return @"inAppSafari"; // unknown token = Apollo's own fallback
}

// Matches the native picker: both Safari modes always, clients only when installed.
static NSArray<NSArray<NSString *> *> *ApolloOpenInAppTweetOptions(void) {
    NSMutableArray<NSArray<NSString *> *> *options = [NSMutableArray array];
    for (NSArray<NSString *> *entry in ApolloOpenInAppTweetClientTable()) {
        if (ApolloOpenInAppTweetClientInstalled(entry[2])) [options addObject:entry];
    }
    return options;
}

// Like Apollo, label "externalBrowser" with the "Open Links in" browser
// (e.g. "Chrome"), but keep "Safari" when that browser is In-App Safari so
// the two options don't read the same.
static NSString *ApolloOpenInAppTweetLabelForToken(NSString *token) {
    if ([token isEqualToString:@"externalBrowser"]) {
        NSString *browserToken = ApolloOpenInAppCurrentBrowserToken();
        if ([browserToken isEqualToString:@"in-app-safari"]) return @"Safari";
        return ApolloOpenInAppBrowserLabelForToken(browserToken);
    }
    for (NSArray<NSString *> *entry in ApolloOpenInAppTweetClientTable()) {
        if ([entry[1] isEqualToString:token]) return entry[0];
    }
    return token; // future/unknown token: show it raw rather than mislabeling it
}

@implementation ApolloOpenInAppViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Open in App";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The mirrored defaults can change while this screen is down the nav
    // stack; every row re-reads its state on configure, so a reload refreshes all.
    [self.tableView reloadData];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    // Plain app names (alphabetical) — the section footer carries the
    // "open links in their app" explanation, so the rows don't repeat it.
    // (X/Twitter isn't a toggle here: Apollo routes tweets through a picker
    // with five possible clients, mirrored as "Open Tweets in" in the Browser
    // section below.)
    ApolloSettingsRow *bluesky =
        [ApolloSettingsRow switchRowWithID:@"bluesky"
                                     title:@"Bluesky"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenLinksInBlueskyApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInBlueskyApp];
        }];

    ApolloSettingsRow *gitHub =
        [ApolloSettingsRow switchRowWithID:@"github"
                                     title:@"GitHub"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenLinksInGitHubApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInGitHubApp];
        }];

    ApolloSettingsRow *steam =
        [ApolloSettingsRow switchRowWithID:@"steam"
                                     title:@"Steam"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenLinksInSteamApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInSteamApp];
        }];

    // Mirror of Apollo's native "Open Videos in YouTube App" switch: same key,
    // so Apollo's own YouTube handling and Reborn's Shorts deep-linking
    // (ApolloShareLinks.xm) both pick the change up live.
    ApolloSettingsRow *youTube =
        [ApolloSettingsRow switchRowWithID:@"youtube"
                                     title:@"YouTube"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenVideosInYouTubeApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenVideosInYouTubeApp];
        }];

    // Mirror of Apollo's native "Open Links in" browser picker: same key, same
    // options (installed browsers only), same tokens.
    ApolloSettingsRow *browser =
        [ApolloSettingsRow valueRowWithID:@"browser"
                                    title:@"Open Links in"
                                   detail:^NSString * { return ApolloOpenInAppBrowserLabelForToken(ApolloOpenInAppCurrentBrowserToken()); }
                                 onSelect:^{ [weakSelf presentBrowserPicker]; }];

    // Mirror of Apollo's "Open Tweets in". Next to the browser row because its
    // "Safari" label follows the browser choice.
    ApolloSettingsRow *tweets =
        [ApolloSettingsRow valueRowWithID:@"tweets"
                                    title:@"Open Tweets in"
                                   detail:^NSString * { return ApolloOpenInAppTweetLabelForToken(ApolloOpenInAppCurrentTweetToken()); }
                                 onSelect:^{ [weakSelf presentTweetPicker]; }];

    // The inverse direction — Safari → Apollo — via the bundled Open in Apollo
    // extension and the Link Companion helper app. The row wears the
    // Companion's real app icon (embedded PNG) rather than a symbol tile.
    ApolloSettingsRow *linkCompanion =
        [ApolloSettingsRow disclosureRowWithID:@"link-companion"
                                         title:@"Open Reddit Links in Apollo"
                                        detail:nil
                                          push:^UIViewController *{
            return [[ApolloLinkCompanionViewController alloc] init];
        }];
    linkCompanion.configure = ^(UITableViewCell *cell) {
        cell.imageView.image = ApolloLinkCompanionIcon(29.0);
    };

    return @[
        [ApolloSettingsSection sectionWithTitle:@"Apps"
                                         footer:@"When enabled, links to these services open directly in their app (if installed) instead of a web view."
                                           rows:@[ bluesky, gitHub, steam, youTube ]],
        [ApolloSettingsSection sectionWithTitle:@"Browser"
                                         footer:@"Choose where web links open. In-App Safari opens links inside Apollo; other browsers appear as they're installed. Tweets can also go to a Twitter client; “Safari” there means the browser above."
                                           rows:@[ browser, tweets ]],
        [ApolloSettingsSection sectionWithTitle:@"Safari"
                                         footer:@"Make Reddit links tapped in Safari open directly in Apollo, with the free Link Companion helper app."
                                           rows:@[ linkCompanion ]],
    ];
}

- (void)presentBrowserPicker {
    NSArray<NSArray<NSString *> *> *options = ApolloOpenInAppBrowserOptions();
    NSString *current = ApolloOpenInAppCurrentBrowserToken();

    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger currentIndex = 0;
    for (NSUInteger i = 0; i < options.count; i++) {
        [titles addObject:options[i][0]];
        if ([options[i][1] isEqualToString:current]) currentIndex = (NSInteger)i;
    }

    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"browser"], @"Open Links in", titles, currentIndex,
                                ^(NSInteger pickedIndex) {
        if (pickedIndex < 0 || pickedIndex >= (NSInteger)options.count) return;
        [[NSUserDefaults standardUserDefaults] setObject:options[pickedIndex][1]
                                                  forKey:UDKeyNativeOpenLinksIn];
        [weakSelf reloadRowWithID:@"browser"];
        // The tweets row renders its "externalBrowser" option through this
        // choice, so it goes stale unless it's reloaded here too.
        [weakSelf reloadRowWithID:@"tweets"];
    });
}

- (void)presentTweetPicker {
    NSArray<NSArray<NSString *> *> *options = ApolloOpenInAppTweetOptions();
    NSString *current = ApolloOpenInAppCurrentTweetToken();

    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger currentIndex = 0;
    for (NSUInteger i = 0; i < options.count; i++) {
        [titles addObject:ApolloOpenInAppTweetLabelForToken(options[i][1])];
        if ([options[i][1] isEqualToString:current]) currentIndex = (NSInteger)i;
    }

    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"tweets"], @"Open Tweets in", titles, currentIndex,
                                ^(NSInteger pickedIndex) {
        if (pickedIndex < 0 || pickedIndex >= (NSInteger)options.count) return;
        [[NSUserDefaults standardUserDefaults] setObject:options[pickedIndex][1]
                                                  forKey:UDKeyNativeOpenTwitterLinksIn];
        [weakSelf reloadRowWithID:@"tweets"];
    });
}

@end
