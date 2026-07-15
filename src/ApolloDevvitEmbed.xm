//
//  ApolloDevvitEmbed.xm
//  Apollo-Reborn
//
//  Reddit's Devvit "interactive posts" (custom apps, e.g. posts on
//  r/CriticalState or r/NBA game threads) come back from the legacy API
//  Apollo talks to as a selftext placeholder:
//  "This post contains content not supported on old Reddit.
//  [Click here to view the full post](https://sh.reddit.com/...)". This file
//  replaces that placeholder, inline, with the actual interactive embed —
//  gated by the `sEnableDevvitEmbeds` settings toggle (off by default: this
//  depends on reverse-engineered, unstable Reddit-internal markup, not a
//  documented API).
//
//  Three pieces:
//   1. Detection — a cheap, offline check against RDKLink.selfTextHTML.
//   2. Extraction (ApolloDevvitEntrypointFetch) — a hidden WKWebView loads the
//      post's reddit.com permalink (the only way past Reddit's JS
//      bot-challenge — same technique as ApolloProfileSocialLinks.m's
//      ApolloSLWebFetch and ApolloSubredditHighlights.xm) and pulls
//      `entrypointUrl`/`postData`/`appPermissionState`/`postStyles.heightPixels`
//      out of the `<devvit2-surface init="...">` JSON embedded in that page.
//   3. Rendering (ApolloDevvitEmbedWebView) — a WKWebView that fabricates its
//      own document as if served from https://www.reddit.com/ (via
//      loadSimulatedRequest, so no real network request happens for it),
//      satisfying the devvit app's `frame-ancestors *.reddit.com` CSP without
//      a local HTTP server, then creates a child <iframe>, sets
//      `contentWindow.name` to the bridge-context payload (the same
//      cross-origin handoff reddit.com's own page uses), and navigates the
//      iframe to `entrypointUrl`. The devvit app boots normally inside that
//      iframe, fully isolated from Reddit's own UI.
//
//  UI injection follows ApolloAISummary.xm's precedent exactly: both hook
//  `_TtC6Apollo22CommentsHeaderCellNode`'s `layoutSpecThatFits:` to splice
//  new content into its Texture layout tree, and both use the same
//  invalidateCalculatedLayout + setNeedsLayout + UITableView
//  beginUpdates/endUpdates + forced display-pass sequence to make an
//  asynchronously-resolved height actually show up (Texture caches the row's
//  old height otherwise — see ApolloAISummary.xm's #526 fix, mirrored here as
//  ApolloDevvitForceHeaderRemeasure). Unlike AISummary (which ADDS a card),
//  this REPLACES the unusable placeholder body outright.
//
//  Comments-header only — feed cells keep the placeholder+link untouched.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

#pragma mark - Texture declarations
//
// Texture (AsyncDisplayKit) headers aren't vendored in this repo — same
// situation ApolloAISummary.xm and ApolloInlineLinkPreviews.xm are in.
// Redeclare only the surface we actually use, matching their pattern.

typedef NS_ENUM(unsigned char, ApolloDevvitStackDirection) {
    ApolloDevvitStackDirectionHorizontal = 0,
    ApolloDevvitStackDirectionVertical = 1,
};
typedef NS_ENUM(unsigned char, ApolloDevvitStackJustifyContent) {
    ApolloDevvitStackJustifyContentStart = 0,
};
typedef NS_ENUM(unsigned char, ApolloDevvitStackAlignItems) {
    ApolloDevvitStackAlignItemsStart = 0,
    ApolloDevvitStackAlignItemsStretch = 3,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASRatioLayoutSpec;
@class ASDisplayNode;

typedef UIView * _Nonnull (^ApolloDevvitViewBlock)(void);

@interface ASDisplayNode : NSObject
- (instancetype)initWithViewBlock:(ApolloDevvitViewBlock)viewBlock;
- (void)addSubnode:(ASDisplayNode *)subnode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (void)invalidateCalculatedLayout;
- (UIView *)view;
- (BOOL)isNodeLoaded;
- (void)onDidLoad:(void (^)(__kindof ASDisplayNode *node))body;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@end

@interface ASLayoutSpec : NSObject
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloDevvitStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloDevvitStackJustifyContent justifyContent;
@property (nonatomic) ApolloDevvitStackAlignItems alignItems;
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) NSUInteger alignContent;
@property (nonatomic) CGFloat lineSpacing;
@property (nullable, nonatomic) NSArray *children;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloDevvitStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloDevvitStackJustifyContent)justifyContent
                                  alignItems:(ApolloDevvitStackAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
@property (nonatomic) UIEdgeInsets insets;
@property (nullable, nonatomic) id child;
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

// Sizes its child to a fixed aspect ratio of the available width — used to give
// our height-known-in-advance webview node a concrete row height without
// needing Texture's ASDimension/ASLayoutElementStyle API.
@interface ASRatioLayoutSpec : ASLayoutSpec
@property (nonatomic) CGFloat ratio;
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

// ASSizeRange as emitted by Apollo's class-dumped headers (same shape
// ApolloAISummary.xm's ApolloAISizeRange uses).
struct ApolloDevvitSizeRange { CGSize min; CGSize max; };

#pragma mark - Tuning

static NSTimeInterval const kApolloDevvitPollInterval = 2.0;
static NSInteger const kApolloDevvitMaxPolls = 8;          // ~ same budget as ApolloSLWebFetch
static NSInteger const kApolloDevvitExtraPollsPastLoad = 2; // let devvit2-surface hydrate after shreddit-app mounts
static CGFloat const kApolloDevvitDefaultHeight = 480.0;    // used if postStyles.heightPixels is missing
// Reddit's own web UI rounds post/card containers — the embed (and its
// loading/tap-to-load placeholder) match that instead of sitting in a sharp
// rectangle, which looked out of place against the rest of Apollo's rounded
// cards. Shared by both the WKWebView (direct CALayer rounding) and the
// placeholder ASTextNode's background (via ASDisplayNode.cornerRadius) so
// they're visually consistent with each other.
static CGFloat const kApolloDevvitCornerRadius = 12.0;

// The rendering technique (WKWebView.loadSimulatedRequest:response:responseData:)
// only exists on iOS 15+, but this tweak's device target floor is iOS 14 (see
// Makefile's TARGET). Gate the whole feature on it rather than crashing
// -doesNotRecognizeSelector: on an iOS 14 device; extraction/UI simply never
// engage below iOS 15, falling back to the stock placeholder+link.
static BOOL ApolloDevvitAvailable(void) {
    if (@available(iOS 15.0, *)) return YES;
    return NO;
}

#pragma mark - Detection

// Tweak.h's hand-maintained RDKLink stub (the interface visible throughout
// this codebase — see that file) has no `identifier` property, only
// `fullName` ("t3_<id>"). Every Link fullname carries that 3-character kind
// prefix, so strip it rather than adding a second, conflicting RDKLink
// interface just for one field.
static NSString *ApolloDevvitPostIdentifier(RDKLink *link) {
    NSString *fullName = link.fullName;
    if (fullName.length <= 3) return nil;
    return [fullName substringFromIndex:3];
}

// Tweak.h declares `permalink` as NSString, but the real runtime property (per
// the class-dumped Headers/ObjC/RDKLink.h, and confirmed by a crash here —
// -[NSURL length]: unrecognized selector — when this trusted the stub) is a
// *relative* NSURL, e.g. "/r/sub/comments/id/title/". ApolloShareAsVideo.xm
// and ApolloShareAsImageLink.xm hit the same staleness and work around it by
// calling through objc_msgSend instead of dot-syntax so the compiler's
// (wrong) static type never enters into it; mirrored here, with an NSString
// fallback kept only in case some other Apollo version genuinely returns one.
static NSURL *ApolloDevvitAbsolutePermalinkURL(RDKLink *link) {
    id raw = ((id (*)(id, SEL))objc_msgSend)(link, @selector(permalink));
    NSString *path = nil;
    if ([raw isKindOfClass:[NSURL class]]) {
        NSURL *u = (NSURL *)raw;
        if (u.scheme.length > 0 && u.host.length > 0) return u; // already absolute
        path = u.relativeString;
    } else if ([raw isKindOfClass:[NSString class]]) {
        path = (NSString *)raw;
    }
    if (path.length == 0) return nil;
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    return [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:path]];
}

// Cheap, offline: is this post Reddit's own "not supported on old Reddit"
// Devvit placeholder? We match structurally (a self-referential link to
// /comments/<this post's id>) rather than the literal English sentence, so it
// survives wording/localization changes.
//
// No length cap on the body: devvit apps can prepend their own real
// developer-authored content above Reddit's auto-appended fallback sentence
// (a genuine post seen in the wild had far more than a short placeholder's
// worth of text before the "not supported" link), so gating on a short body
// produced false negatives on exactly the posts this feature is for. A
// short-body requirement was originally there to guard against a genuine
// self-text post happening to link to itself, but a user can't know their
// own post's id at compose time — a /comments/<own-id> link appearing at all
// is already a strong, close-to-unique signal on its own, with or without a
// length bound. Keep a generous sanity cap only against pathological input.
static BOOL ApolloDevvitLinkIsPlaceholder(RDKLink *link) {
    if (!link) return NO;
    if (!link.selfPost) return NO;
    NSString *html = link.selfTextHTML.length > 0 ? link.selfTextHTML : link.selfText;
    if (html.length == 0 || html.length > 20000) return NO;

    NSString *identifier = ApolloDevvitPostIdentifier(link);
    if (identifier.length == 0) return NO;

    NSString *marker = [NSString stringWithFormat:@"/comments/%@", identifier];
    if ([html rangeOfString:marker].location == NSNotFound) return NO;
    if ([html rangeOfString:@"reddit.com" options:NSCaseInsensitiveSearch].location == NSNotFound) return NO;
    return YES;
}

#pragma mark - Result cache (embeddable yes/no only — entrypointUrl is never cached, its token is short-lived)

typedef NS_ENUM(NSInteger, ApolloDevvitEmbeddable) {
    ApolloDevvitEmbeddableUnknown = 0,
    ApolloDevvitEmbeddableYes,
    ApolloDevvitEmbeddableNo,
};

static NSMutableDictionary<NSString *, NSNumber *> *ApolloDevvitEmbeddableCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

#pragma mark - Extraction (hidden WKWebView scrape)

@interface ApolloDevvitEntrypointFetch : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, copy) void (^done)(NSDictionary *result); // nil result = retry later (not cached)
@property (nonatomic) NSInteger polls;
@property (nonatomic) NSInteger loadedEmptyPolls;
@property (nonatomic) BOOL sawLoaded;
@end

@implementation ApolloDevvitEntrypointFetch

// Shared, logged-out, in-memory WKWebsiteDataStore — same rationale as
// ApolloSLWebFetch's apollo_scrapeDataStore: keeps this scrape from
// poisoning/being poisoned by the user's real signed-in session, and lets
// Reddit's bot-challenge cookie warm once per app session instead of cold on
// every post.
+ (WKWebsiteDataStore *)apollo_devvitDataStore {
    static WKWebsiteDataStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [WKWebsiteDataStore nonPersistentDataStore]; });
    return store;
}

- (void)startForLink:(RDKLink *)link completion:(void (^)(NSDictionary *result))done {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startForLink:link completion:done]; });
        return;
    }
    self.fullName = link.fullName;
    self.done = done;
    self.polls = 0;
    self.loadedEmptyPolls = 0;
    self.sawLoaded = NO;

    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) win = w; }
    }
    if (!win) win = ApolloAllWindows().firstObject;
    if (!win) { [self finish:nil]; return; }

    // sh.reddit.com just 301s to www.reddit.com anyway, so resolve straight there.
    NSURL *url = ApolloDevvitAbsolutePermalinkURL(link);
    if (!url) { [self finish:nil]; return; }

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [ApolloDevvitEntrypointFetch apollo_devvitDataStore];
    self.web = [[WKWebView alloc] initWithFrame:win.bounds configuration:config];
    self.web.navigationDelegate = self;
    self.web.alpha = 0.011;
    self.web.userInteractionEnabled = NO;
    self.web.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    [win insertSubview:self.web atIndex:0];
    [self.web loadRequest:[NSURLRequest requestWithURL:url]];
    ApolloLog(@"[DevvitEmbed][web] loading %@ for %@", url, self.fullName);
    [self pollAfter:3.0];
}

- (void)pollAfter:(double)d {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws poll]; });
}

- (NSString *)extractionJS {
    return
    @"(function(){"
    "var challenge = /verification/i.test(document.title || '');"
    "var loaded = !!document.querySelector('shreddit-app') && !challenge;"
    "var surface = document.querySelector('devvit2-surface');"
    "var data = null;"
    "if (surface) { var raw = surface.getAttribute('init'); if (raw) { try { data = JSON.parse(raw); } catch (e) {} } }"
    "return JSON.stringify({"
    "  ready: document.readyState,"
    "  loaded: loaded,"
    "  entrypointUrl: (data && data.entrypointUrl) || null,"
    "  postData: (data && data.postData) || null,"
    "  appPermissionState: (data && data.appPermissionState) || null,"
    "  heightPixels: (data && data.postStyles && data.postStyles.heightPixels) || null"
    "});"
    "})()";
}

- (void)poll {
    if (!self.web) return;
    self.polls++;
    __weak typeof(self) ws = self;
    [self.web evaluateJavaScript:[self extractionJS] completionHandler:^(id res, NSError *e) {
        typeof(self) ss = ws; if (!ss) return;
        if (e) ApolloLog(@"[DevvitEmbed][web] %@ JS error (poll#%ld): %@", ss.fullName, (long)ss.polls, e.localizedDescription);
        NSString *s = [res isKindOfClass:[NSString class]] ? res : @"{}";
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) j = @{};

        BOOL loaded = [j[@"loaded"] boolValue];
        if (loaded) ss.sawLoaded = YES;

        NSString *entrypointUrlString = [j[@"entrypointUrl"] isKindOfClass:[NSString class]] ? j[@"entrypointUrl"] : nil;
        if (loaded && entrypointUrlString.length > 0) {
            NSURL *entrypointUrl = [NSURL URLWithString:entrypointUrlString];
            if (entrypointUrl) {
                ApolloLog(@"[DevvitEmbed][web] %@ found entrypointUrl (poll#%ld)", ss.fullName, (long)ss.polls);
                [ss finish:@{
                    @"embeddable": @YES,
                    @"entrypointUrl": entrypointUrl,
                    @"postData": j[@"postData"] ?: @{},
                    @"appPermissionState": j[@"appPermissionState"] ?: @{},
                    @"heightPixels": j[@"heightPixels"] ?: @(kApolloDevvitDefaultHeight),
                }];
                return;
            }
        }

        if (loaded) {
            ss.loadedEmptyPolls++;
            // Give devvit2-surface a couple extra polls to hydrate past the
            // initial shreddit-app mount before concluding this really isn't a
            // webview-capable devvit post (Blocks-only, or markup changed).
            if (ss.loadedEmptyPolls >= kApolloDevvitExtraPollsPastLoad) {
                ApolloLog(@"[DevvitEmbed][web] %@ resolved: not webview-embeddable", ss.fullName);
                [ss finish:@{@"embeddable": @NO}];
                return;
            }
        }

        if (ss.polls >= kApolloDevvitMaxPolls) {
            // Saw a real load but never found the surface -> confirmed not
            // embeddable. Never got past the bot-challenge/load at all -> nil,
            // so the caller retries on a future visit instead of caching a
            // false negative.
            ApolloLog(@"[DevvitEmbed][web] %@ timed out (sawLoaded=%d)", ss.fullName, ss.sawLoaded);
            [ss finish:ss.sawLoaded ? @{@"embeddable": @NO} : nil];
            return;
        }
        [ss pollAfter:kApolloDevvitPollInterval];
    }];
}

- (void)finish:(NSDictionary *)result {
    if (self.web) { self.web.navigationDelegate = nil; [self.web stopLoading]; [self.web removeFromSuperview]; self.web = nil; }
    void (^d)(NSDictionary *) = self.done; self.done = nil;
    if (d) d(result);
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {}

@end

// completion(result) on the main queue — result is nil on failure (retry later,
// not cached), @{"embeddable": @NO} for a confirmed non-webview devvit post
// (cached), or the full dictionary (embeddable/entrypointUrl/postData/
// appPermissionState/heightPixels) on success (embeddable flag cached, the
// rest is NOT — always re-fetched fresh right before actually rendering,
// since entrypointUrl's token is session/time-scoped).
static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloDevvitPending(void) {
    static NSMutableDictionary *pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; });
    return pending;
}
static NSMutableDictionary<NSString *, ApolloDevvitEntrypointFetch *> *ApolloDevvitFetchers(void) {
    static NSMutableDictionary *fetchers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fetchers = [NSMutableDictionary dictionary]; });
    return fetchers;
}

static void ApolloDevvitFetchEntrypoint(RDKLink *link, void (^completion)(NSDictionary *result)) {
    NSString *key = link.fullName ?: @"";
    if (key.length == 0) { if (completion) completion(nil); return; }

    NSNumber *cachedEmbeddable = ApolloDevvitEmbeddableCache()[key];
    if ([cachedEmbeddable isEqual:@(ApolloDevvitEmbeddableNo)]) {
        if (completion) completion(@{@"embeddable": @NO});
        return;
    }

    NSMutableArray *waiters = ApolloDevvitPending()[key];
    if (waiters) { if (completion) [waiters addObject:[completion copy]]; return; }
    waiters = [NSMutableArray array];
    if (completion) [waiters addObject:[completion copy]];
    ApolloDevvitPending()[key] = waiters;

    ApolloDevvitEntrypointFetch *fetch = [[ApolloDevvitEntrypointFetch alloc] init];
    ApolloDevvitFetchers()[key] = fetch;
    [fetch startForLink:link completion:^(NSDictionary *result) {
        if (result) {
            BOOL embeddable = [result[@"embeddable"] boolValue];
            ApolloDevvitEmbeddableCache()[key] = @(embeddable ? ApolloDevvitEmbeddableYes : ApolloDevvitEmbeddableNo);
        }
        NSArray *toNotify = ApolloDevvitPending()[key];
        [ApolloDevvitPending() removeObjectForKey:key];
        [ApolloDevvitFetchers() removeObjectForKey:key];
        for (void (^waiter)(NSDictionary *) in toNotify) waiter(result);
    }];
}

#pragma mark - Rendering (the proven loadSimulatedRequest + iframe + window.name technique)

@interface ApolloDevvitEmbedWebView : WKWebView <WKNavigationDelegate>
- (instancetype)initWithFrame:(CGRect)frame
                 entrypointURL:(NSURL *)entrypointURL
                      postData:(NSDictionary *)postData
            appPermissionState:(NSDictionary *)appPermissionState;
@end

@implementation ApolloDevvitEmbedWebView {
    NSURL *_apollo_entrypointURL;
    NSDictionary *_apollo_postData;
    NSDictionary *_apollo_appPermissionState;
}

- (instancetype)initWithFrame:(CGRect)frame
                 entrypointURL:(NSURL *)entrypointURL
                      postData:(NSDictionary *)postData
            appPermissionState:(NSDictionary *)appPermissionState {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self = [super initWithFrame:frame configuration:config];
    if (!self) return nil;
    _apollo_entrypointURL = entrypointURL;
    _apollo_postData = postData ?: @{};
    _apollo_appPermissionState = appPermissionState ?: @{};
    self.navigationDelegate = self;
    // Opt in to Safari's remote Web Inspector for this webview (off by
    // default for third-party-app WKWebViews; without it Safari's Develop
    // menu shows no inspectable content here at all).
    if (@available(iOS 16.4, *)) self.inspectable = YES;
    // Lock pinch-zoom on the wrapper (it has no real content to zoom — the
    // iframe should fill it via CSS). Deliberately NOT touching
    // scrollView.scrollEnabled/bounces here: disabling those turned out to
    // also suppress touch routing into the iframe's own content (drags fell
    // through to the outer post's UITableView instead of scrolling/tapping
    // inside the embed) — leave scrolling alone and let the (now correctly
    // sized) fixed-position iframe make the wrapper's own body non-scrollable
    // on its own.
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 1.0;
    // Many devvit apps have no real scrollable content at all (custom
    // on-screen buttons instead of drag-to-scroll), so a drag over them
    // should fall through to scroll the surrounding post, matching the real
    // reddit.com website. UIScrollView.panGestureRecognizer.delegate can't be
    // reassigned to achieve this — it's reserved for the scroll view's own
    // internal bookkeeping and UIKit hard-crashes
    // (-[UIScrollViewPanGestureRecognizer setDelegate:]) if you try. Turning
    // off bounce instead: with nothing to scroll AND no rubber-banding, our
    // own scroll view has nothing to do with the touch at all, which is what
    // lets UIKit's ordinary nested-scroll-view handoff give it to Apollo's
    // outer UITableView instead, with no custom delegate wiring needed.
    self.scrollView.bounces = NO;
    self.scrollView.alwaysBounceVertical = NO;
    self.scrollView.alwaysBounceHorizontal = NO;
    // Reddit's own post cards are rounded; a sharp-cornered rectangle here
    // looked out of place. WKWebView is a plain UIView we fully own, so this
    // is just a normal CALayer mask — no CSS/iframe changes needed.
    self.layer.cornerRadius = kApolloDevvitCornerRadius;
    self.layer.masksToBounds = YES;
    [self apollo_loadWrapper];
    return self;
}

- (void)apollo_loadWrapper {
    NSURL *wrapperURL = [NSURL URLWithString:@"https://www.reddit.com/apollo-reborn-devvit-bridge"];
    NSString *wrapperHTML = @"<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no\">"
        "<title>Devvit Embed</title>"
        "<style>html,body{margin:0;padding:0;width:100%;height:100%;background:transparent}</style></head><body></body></html>";
    NSData *wrapperData = [wrapperHTML dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *wrapperResponse = [[NSHTTPURLResponse alloc] initWithURL:wrapperURL
                                                                       statusCode:200
                                                                      HTTPVersion:@"HTTP/1.1"
                                                                     headerFields:@{@"Content-Type": @"text/html; charset=utf-8"}];
    // Fabricates the document as if served from reddit.com — no real network
    // request happens for this load. Satisfies the devvit CSP's
    // `frame-ancestors *.reddit.com` for the child iframe below. iOS 15+ only
    // (this tweak's device floor is iOS 14); every path that can construct an
    // ApolloDevvitEmbedWebView is already gated on ApolloDevvitAvailable(),
    // this is just belt-and-suspenders against ever reaching it on iOS 14.
    if (@available(iOS 15.0, *)) {
        [self loadSimulatedRequest:[NSURLRequest requestWithURL:wrapperURL] response:wrapperResponse responseData:wrapperData];
    }
}

- (NSDictionary *)apollo_bridgeContext {
    NSString *token = nil;
    NSURLComponents *comps = [NSURLComponents componentsWithURL:_apollo_entrypointURL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in comps.queryItems) {
        if ([item.name isEqualToString:@"token"]) { token = item.value; break; }
    }
    NSString *origin = [NSString stringWithFormat:@"%@://%@%@", _apollo_entrypointURL.scheme, _apollo_entrypointURL.host,
                         _apollo_entrypointURL.port ? [NSString stringWithFormat:@":%@", _apollo_entrypointURL.port] : @""];
    return @{
        @"appPermissionState": _apollo_appPermissionState,
        @"client": @3,
        @"devvitDebug": @"",
        @"postData": _apollo_postData,
        @"shredditVersion": @{@"major": @0, @"minor": @13, @"patch": @6, @"version": @"0.13.6"},
        @"signedRequestContext": token ?: @"",
        @"startTime": @([[NSDate date] timeIntervalSince1970] * 1000.0),
        @"viewMode": @1,
        @"webbitToken": @"",
        @"webViewClientData": @{
            @"appConfig": @{
                @"entrypoints": @{
                    @"default": [NSString stringWithFormat:@"%@/index.html", origin],
                    @"small": [NSString stringWithFormat:@"%@/small.html", origin],
                }
            }
        },
    };
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {
    // Only the wrapper's own top-level load reaches here with this host — the
    // subsequent iframe navigation to entrypointURL doesn't trigger the
    // WKWebView-level didFinishNavigation (it's a sub-frame navigation).
    if (![wv.URL.host isEqualToString:@"www.reddit.com"]) return;

    NSDictionary *bridgeContext = [self apollo_bridgeContext];
    NSData *bridgeData = [NSJSONSerialization dataWithJSONObject:bridgeContext options:0 error:nil];
    NSString *bridgeJSON = bridgeData ? [[NSString alloc] initWithData:bridgeData encoding:NSUTF8StringEncoding] : @"{}";

    // window.name is how reddit.com's own page hands the devvit SDK its
    // session/token bridge context; it survives same-tab child-frame
    // navigation (unlike a bare top-level location.href, which browsers clear
    // on cross-origin navigation for exactly this data-smuggling reason —
    // that's why this has to be a real <iframe>, not a direct top-level nav).
    // NB: the CSS below is itself the -stringWithFormat: template, so its
    // literal "100%" percent signs must be doubled to "100%%" — an
    // un-doubled "%" here previously got eaten by format-string parsing,
    // silently mangling the CSS into something invalid. That left the
    // iframe with no explicit sizing at all, so it fell back to the browser's
    // unstyled default box (~150pt tall) instead of filling the webview —
    // which is exactly the undersized/corner rendering this was causing.
    NSString *js =
        @"var f = document.createElement('iframe');"
         "f.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;width:100%%;height:100%%;border:0';"
         "document.body.appendChild(f);"
         "f.contentWindow.name = %@;"
         "f.src = %@;";
    NSString *bridgeJSONLiteral = [NSString stringWithFormat:@"JSON.stringify(%@)", bridgeJSON];
    NSString *escapedEntrypoint = [_apollo_entrypointURL.absoluteString stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *entrypointLiteral = [NSString stringWithFormat:@"\"%@\"", escapedEntrypoint];
    NSString *script = [NSString stringWithFormat:js, bridgeJSONLiteral, entrypointLiteral];
    [self evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error) ApolloLog(@"[DevvitEmbed][render] iframe injection failed: %@", error.localizedDescription);
    }];
}

@end

#pragma mark - Header remeasure helpers (copied from ApolloAISummary.xm's proven #526 fix — see
#pragma mark   ApolloAIRealizeHeaderNodeDisplay/ApolloAIForceHeaderRemeasure for the original)
#pragma mark
#pragma mark   Unlike AISummary (which fans a change out to every live header for a
#pragma mark   fullName via a weak registry), each completion below already has a
#pragma mark   direct weak reference to the one cell instance it's for, so no
#pragma mark   separate registry is needed here.

static const void *kApolloDevvitStateKey = &kApolloDevvitStateKey;
static const void *kApolloDevvitTappedKey = &kApolloDevvitTappedKey;
static const void *kApolloDevvitLoadingKey = &kApolloDevvitLoadingKey;
static const void *kApolloDevvitEmbedNodeKey = &kApolloDevvitEmbedNodeKey;

static void ApolloDevvitRealizeHeaderNodeDisplay(id headerNode) {
    if (!headerNode) return;
    if ([headerNode respondsToSelector:@selector(isNodeLoaded)] &&
        !(((BOOL (*)(id, SEL))objc_msgSend)(headerNode, @selector(isNodeLoaded)))) return;
    if ([headerNode respondsToSelector:@selector(setNeedsLayout)])
        ((void (*)(id, SEL))objc_msgSend)(headerNode, @selector(setNeedsLayout));
    if ([headerNode respondsToSelector:@selector(layoutIfNeeded)])
        ((void (*)(id, SEL))objc_msgSend)(headerNode, @selector(layoutIfNeeded));
    if ([headerNode respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(headerNode, @selector(recursivelyEnsureDisplaySynchronously:), YES);
}

static UITableView *ApolloDevvitTableViewForHeaderNode(id headerNode) {
    if (!headerNode || ![headerNode respondsToSelector:@selector(view)]) return nil;
    if ([headerNode respondsToSelector:@selector(isNodeLoaded)] &&
        !(((BOOL (*)(id, SEL))objc_msgSend)(headerNode, @selector(isNodeLoaded)))) return nil;
    UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(headerNode, @selector(view));
    for (UIView *cur = v; cur; cur = cur.superview) {
        if ([cur isKindOfClass:[UITableView class]]) return (UITableView *)cur;
    }
    return nil;
}

// Walks the UIResponder chain (not just superviews — this crosses view ->
// view-controller boundaries) from the node's backing view up to the owning
// UIViewController. Used to match tracked header cells against the
// CommentsViewController that's actually disappearing, below.
static UIViewController *ApolloDevvitEnclosingViewController(id node) {
    if (!node || ![node respondsToSelector:@selector(view)]) return nil;
    if ([node respondsToSelector:@selector(isNodeLoaded)] &&
        !(((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(isNodeLoaded)))) return nil;
    UIResponder *responder = ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view));
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

// Weak registry of every CommentsHeaderCellNode we've touched, so
// CommentsViewController's -viewDidDisappear: (see the hook below) can find
// and tear down whichever of them it actually owns. Apollo's own
// swipe-forward feature (ApolloNavigationController's poppedViewControllers
// cache — see AGENTS.md/CLAUDE.md-adjacent research) deliberately keeps
// popped comments screens, and thus their cells, alive so the gesture can
// restore them instantly. That means Texture's own -didExitDisplayState
// rendering-visibility signal never reliably fires for a popped screen (the
// view is still attached, just off the visible nav stack) — so unlike a
// normal "cell scrolled off screen" case, we need the real *navigation*
// signal instead, which only the owning view controller can tell us.
static NSHashTable *ApolloDevvitTrackedCells(void) {
    static NSHashTable *cells;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cells = [NSHashTable weakObjectsHashTable]; });
    return cells;
}

static void ApolloDevvitForceHeaderRemeasure(id headerNode) {
    if (!headerNode) return;
    UITableView *tableView = ApolloDevvitTableViewForHeaderNode(headerNode);
    if (!tableView) return;
    [tableView beginUpdates];
    [tableView endUpdates];
    ApolloDevvitRealizeHeaderNodeDisplay(headerNode);
}

// Stops a devvit embed node's WKWebView and releases its JS heap /
// WebContent resources promptly rather than leaving that to ARC's timing.
static void ApolloDevvitStopWebViewNode(ASDisplayNode *node) {
    if (!node || ![node isNodeLoaded]) return; // viewBlock never ran — no WKWebView was ever actually created
    UIView *view = node.view;
    if (![view isKindOfClass:[WKWebView class]]) return;
    WKWebView *webView = (WKWebView *)view;
    webView.navigationDelegate = nil;
    [webView stopLoading];
    [webView loadHTMLString:@"" baseURL:nil];
}

// Per-POST (not per-cell) registry of the currently-live embed node. Texture
// recreates CommentsHeaderCellNode instances under this class multiple times
// over the course of viewing a single post — observed directly: 3-4 distinct
// cell pointers, all resolving the same post, within one open — likely
// triggered by our own -beginUpdates/-endUpdates remeasure call causing the
// table to dequeue a fresh header rather than resizing the existing one, for
// reasons not fully tracked down. Relying on per-cell teardown alone
// (-didExitDisplayState/-dealloc/the CommentsViewController hook) leaves
// every earlier, now-orphaned cell's webview running, since none of those
// signals ever fire for a cell Texture has silently abandoned — that's what
// produced 4 live webviews from repeatedly opening/closing one post. This
// registry sidesteps the "why does the cell change" question entirely: on
// every occasion any cell builds a fresh embed node for a given post, we tear
// down whatever was previously live for that SAME post first, so there's
// never more than one live webview per post regardless of how many cell
// incarnations asked for one.
static NSMutableDictionary<NSString *, ASDisplayNode *> *ApolloDevvitLiveEmbedByPost(void) {
    static NSMutableDictionary *live;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ live = [NSMutableDictionary dictionary]; });
    return live;
}

// Retires whatever embed node was previously live for `fullName` (if any,
// and if different from `newNode`), then records `newNode` as the new one.
static void ApolloDevvitRetireAndRegisterLiveEmbed(NSString *fullName, ASDisplayNode *newNode) {
    if (fullName.length == 0) return;
    NSMutableDictionary *live = ApolloDevvitLiveEmbedByPost();
    ASDisplayNode *previous = live[fullName];
    if (previous && previous != newNode) {
        ApolloDevvitStopWebViewNode(previous);
    }
    if (newNode) {
        live[fullName] = newNode;
    } else {
        [live removeObjectForKey:fullName];
    }
}

// Stops and releases a cell's cached embed webview (if one was ever actually
// built), and drops it from the live-by-post registry if it's still the
// current entry there. Called on both -didExitDisplayState (the post is no
// longer being viewed — the common case) and -dealloc (belt-and-suspenders,
// in case the cell outlives display state for some other reason).
static void ApolloDevvitTeardownEmbedNode(id cell) {
    ASDisplayNode *node = objc_getAssociatedObject(cell, kApolloDevvitEmbedNodeKey);
    if (!node) return;
    objc_setAssociatedObject(cell, kApolloDevvitEmbedNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableDictionary *live = ApolloDevvitLiveEmbedByPost();
    for (NSString *key in [live allKeysForObject:node]) {
        [live removeObjectForKey:key];
    }
    ApolloDevvitStopWebViewNode(node);
}

#pragma mark - Layout injection: locate the MarkdownNode body and replace it

// Rebuild a stack spec with new children, preserving its layout attributes.
static ASStackLayoutSpec *ApolloDevvitRebuildStack(ASStackLayoutSpec *stack, NSArray *children) {
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    ASStackLayoutSpec *s = [stackClass stackLayoutSpecWithDirection:stack.direction
                                                             spacing:stack.spacing
                                                      justifyContent:stack.justifyContent
                                                          alignItems:stack.alignItems
                                                            children:children];
    s.flexWrap = stack.flexWrap;
    s.alignContent = stack.alignContent;
    s.lineSpacing = stack.lineSpacing;
    return s;
}

// Recurse into nested stacks (self-posts wrap title/body in a nested stack,
// same as ApolloAISummary.xm's ApolloAIInsertPostSummary) looking for the
// MarkdownNode body, and replace it in place with `replacement`.
static ASStackLayoutSpec *ApolloDevvitReplaceBody(ASStackLayoutSpec *stack, id replacement, NSUInteger depth) {
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (![stack isKindOfClass:stackClass] || depth > 4) return nil;
    Class markdownClass = NSClassFromString(@"_TtC6Apollo12MarkdownNode");
    NSArray *children = stack.children ?: @[];

    for (NSUInteger i = 0; i < children.count; i++) {
        id c = children[i];
        if ((markdownClass && [c isKindOfClass:markdownClass]) ||
            [NSStringFromClass([c class]) isEqualToString:@"Apollo.MarkdownNode"]) {
            NSMutableArray *m = [children mutableCopy];
            m[i] = replacement;
            return ApolloDevvitRebuildStack(stack, m);
        }
    }
    for (NSUInteger i = 0; i < children.count; i++) {
        id c = children[i];
        if ([c isKindOfClass:stackClass]) {
            ASStackLayoutSpec *rebuilt = ApolloDevvitReplaceBody((ASStackLayoutSpec *)c, replacement, depth + 1);
            if (rebuilt) {
                NSMutableArray *m = [children mutableCopy];
                m[i] = rebuilt;
                return ApolloDevvitRebuildStack(stack, m);
            }
        }
    }
    return nil;
}

// Preserve Apollo's root width/inset semantics (same recursion shape as
// ApolloAISummary.xm's ApolloAIPlaceSummariesPreservingRoot).
static id ApolloDevvitPlaceReplacementPreservingRoot(id rootSpec, id replacement) {
    if (!rootSpec || !replacement) return nil;

    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (stackClass && [rootSpec isKindOfClass:stackClass]) {
        return ApolloDevvitReplaceBody((ASStackLayoutSpec *)rootSpec, replacement, 0);
    }

    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    if (insetClass && [rootSpec isKindOfClass:insetClass]) {
        ASInsetLayoutSpec *originalInset = (ASInsetLayoutSpec *)rootSpec;
        id newChild = ApolloDevvitPlaceReplacementPreservingRoot(originalInset.child, replacement);
        if (!newChild) return nil;
        return [insetClass insetLayoutSpecWithInsets:originalInset.insets child:newChild];
    }
    return nil;
}

#pragma mark - Weak gesture-recognizer target trampoline

// UIGestureRecognizer retains its target. A gesture on a node that's owned by
// a cell, targeting that same cell, is a plain retain cycle. This trampoline
// is what the gesture recognizer actually retains; it forwards to `target`
// only while that's still alive.
@interface ApolloDevvitWeakGestureTarget : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@end

@implementation ApolloDevvitWeakGestureTarget
- (void)apollo_devvitInvoke {
    id t = self.target;
    if (t && self.action && [t respondsToSelector:self.action]) {
        ((void (*)(id, SEL))objc_msgSend)(t, self.action);
    }
}
@end

// The replacement node/spec: either the live embed webview (sized to
// heightPixels via ASRatioLayoutSpec) or, before that's ready, a lightweight
// placeholder — a "Loading…" label while an auto-load fetch is in flight, or
// a tappable "View Interactive Post" label in tap-to-load mode (calls
// -apollo_devvitTapTargetTapped on `tapTarget`, the owning cell, when tapped).
static id ApolloDevvitEmbedSpec(NSDictionary *state, CGFloat availableWidth, id tapTarget, BOOL loading, NSString *fullName) {
    Class ratioClass = NSClassFromString(@"ASRatioLayoutSpec");
    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    if (!ratioClass || !insetClass) return nil;

    UIEdgeInsets insets = UIEdgeInsetsMake(8, 14, 8, 14);
    CGFloat heightPixels = [state[@"heightPixels"] doubleValue];
    NSURL *entrypointUrl = state[@"entrypointUrl"];
    if (heightPixels <= 0) heightPixels = entrypointUrl ? kApolloDevvitDefaultHeight : 44.0;
    CGFloat width = availableWidth > 0 ? availableWidth : 375.0;
    CGFloat contentWidth = MAX(1, width - insets.left - insets.right);
    CGFloat ratio = heightPixels / contentWidth;

    ASDisplayNode *node;
    if (entrypointUrl) {
        // layoutSpecThatFits: can (and does, e.g. on every scroll-driven
        // re-measurement pass) get called many times for the same cell —
        // it's supposed to be a pure function of constrainedSize. Building a
        // fresh ASDisplayNode(viewBlock:) here every time was creating a
        // brand new WKWebView (and re-running the whole load-wrapper/
        // create-iframe/navigate dance) on every single pass, which is
        // exactly the "goes black and reloads while scrolling" symptom.
        // Cache the node on the cell once and reuse it from then on — same
        // idea as ApolloAISummary.xm's ApolloAIEnsureSummaryNode.
        ASDisplayNode *cached = objc_getAssociatedObject(tapTarget, kApolloDevvitEmbedNodeKey);
        ApolloLog(@"[DevvitEmbed][lifecycle] ApolloDevvitEmbedSpec cell=%p cachedNode=%s", tapTarget, cached ? "reused" : "CREATING NEW");
        if (cached) {
            node = cached;
        } else {
            NSDictionary *postData = state[@"postData"];
            NSDictionary *appPermissionState = state[@"appPermissionState"];
            // WKWebView (and the devvit app's own JS, which measures its available
            // space once early during boot rather than tracking resize events) needs
            // to start life at roughly its real final size — creating it at
            // CGRectZero and letting Texture's later layout pass resize the view
            // left the game rendering into a tiny top-left corner instead of
            // filling the frame, since by the time the resize happened the app had
            // already measured a 0x0 viewport.
            CGRect initialFrame = CGRectMake(0, 0, contentWidth, heightPixels);
            node = [[NSClassFromString(@"ASDisplayNode") alloc] initWithViewBlock:^UIView * _Nonnull {
                return [[ApolloDevvitEmbedWebView alloc] initWithFrame:initialFrame
                                                           entrypointURL:entrypointUrl
                                                                postData:postData
                                                      appPermissionState:appPermissionState];
            }];
            // Texture nodes default userInteractionEnabled to NO, which was
            // propagating down to the backing WKWebView and swallowing all its
            // touches — drags fell through to the underlying comments
            // UITableView instead of scrolling/tapping inside the embed.
            node.userInteractionEnabled = YES;
            objc_setAssociatedObject(tapTarget, kApolloDevvitEmbedNodeKey, node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // Whatever was previously live for THIS post (built by an earlier,
            // now-orphaned incarnation of the cell) is superseded by this one —
            // tear it down now instead of waiting on a per-cell signal that may
            // never fire for an abandoned cell.
            ApolloDevvitRetireAndRegisterLiveEmbed(fullName, node);
        }
    } else {
        // Placeholder — a simple text node. ASDisplayNode-backed views are
        // real UIViews, so a plain UITapGestureRecognizer attached once the
        // node loads works the same as on any other UIView.
        Class textClass = NSClassFromString(@"ASTextNode");
        ASTextNode *text = [textClass new];
        text.maximumNumberOfLines = 1;
        // Match the embed webview's rounding + give the placeholder a fill,
        // so the rounding actually reads as a card instead of clipping
        // nothing — a transparent background has no visible corners.
        text.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        text.cornerRadius = kApolloDevvitCornerRadius;
        text.clipsToBounds = YES;
        NSMutableParagraphStyle *centered = [NSMutableParagraphStyle new];
        centered.alignment = NSTextAlignmentCenter;
        if (loading) {
            text.userInteractionEnabled = NO;
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:15],
                NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
                NSParagraphStyleAttributeName: centered,
            };
            text.attributedText = [[NSAttributedString alloc] initWithString:@"Loading Interactive Post…" attributes:attrs];
        } else {
            text.userInteractionEnabled = YES;
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:15],
                NSForegroundColorAttributeName: [UIColor linkColor],
                NSParagraphStyleAttributeName: centered,
            };
            text.attributedText = [[NSAttributedString alloc] initWithString:@"View Interactive Post" attributes:attrs];
            [text onDidLoad:^(__kindof ASDisplayNode *loadedNode) {
                // UIGestureRecognizer retains its target, and this node (via
                // Texture's normal subnode ownership) is retained by the cell
                // — targeting `tapTarget` (the cell) directly here would be a
                // textbook retain cycle. Route through a weak-target
                // trampoline instead; the trampoline itself is what the
                // gesture recognizer retains, and it holds the cell weakly.
                ApolloDevvitWeakGestureTarget *proxy = [ApolloDevvitWeakGestureTarget new];
                proxy.target = tapTarget;
                proxy.action = @selector(apollo_devvitTapTargetTapped);
                UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:proxy action:@selector(apollo_devvitInvoke)];
                objc_setAssociatedObject(tap, (__bridge const void *)proxy, proxy, OBJC_ASSOCIATION_RETAIN);
                [loadedNode.view addGestureRecognizer:tap];
            }];
        }
        node = (ASDisplayNode *)text;
    }

    id sized = [ratioClass ratioLayoutSpecWithRatio:ratio child:node];
    return [insetClass insetLayoutSpecWithInsets:insets child:sized];
}

#pragma mark - CommentsHeaderCellNode hook

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didExitDisplayState {
    ApolloDevvitTeardownEmbedNode((id)self);
    %orig;
}

- (void)dealloc {
    // Belt-and-suspenders: -didExitDisplayState is the normal "no longer
    // being viewed" signal and should already have torn this down, but if
    // the cell is ever freed without it firing, don't leave a live WKWebView
    // behind.
    ApolloDevvitTeardownEmbedNode((id)self);
    %orig;
}

- (void)didEnterDisplayState {
    %orig;
    if (!sEnableDevvitEmbeds || !ApolloDevvitAvailable()) return;

    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    if (!ApolloDevvitLinkIsPlaceholder(link)) return;

    [ApolloDevvitTrackedCells() addObject:(id)self];
    ApolloLog(@"[DevvitEmbed][lifecycle] didEnterDisplayState cell=%p tracked-now=%lu hasState=%d",
              self, (unsigned long)ApolloDevvitTrackedCells().count, objc_getAssociatedObject((id)self, kApolloDevvitStateKey) != nil);

    // Already resolved (or in flight) for this cell instance — nothing to do.
    if (objc_getAssociatedObject((id)self, kApolloDevvitStateKey)) return;

    // Tap-to-load: show the tap target immediately (layoutSpecThatFits picks
    // it up on its own since state stays nil / not-yet-fetched), don't start
    // the network fetch until the user taps.
    if (!sDevvitEmbedsAutoLoad) return;

    objc_setAssociatedObject((id)self, kApolloDevvitLoadingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak __typeof__(self) weakSelf = self;
    ApolloDevvitFetchEntrypoint(link, ^(NSDictionary *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            objc_setAssociatedObject((id)strongSelf, kApolloDevvitLoadingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!result) {
                // Timeout — leave state nil so a future visit retries, but swap
                // "Loading…" for the tappable "View Interactive Post" now (same
                // row height either way, so no table remeasure needed).
                [(ASDisplayNode *)(id)strongSelf setNeedsLayout];
                return;
            }
            objc_setAssociatedObject((id)strongSelf, kApolloDevvitStateKey, result, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [(ASDisplayNode *)(id)strongSelf invalidateCalculatedLayout];
            [(ASDisplayNode *)(id)strongSelf setNeedsLayout];
            ApolloDevvitForceHeaderRemeasure((id)strongSelf);
        });
    });
}

%new
- (void)apollo_devvitTapTargetTapped {
    if (!ApolloDevvitAvailable()) return;
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    if (!ApolloDevvitLinkIsPlaceholder(link)) return;
    if (objc_getAssociatedObject((id)self, kApolloDevvitTappedKey)) return;
    objc_setAssociatedObject((id)self, kApolloDevvitTappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((id)self, kApolloDevvitLoadingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [(ASDisplayNode *)(id)self setNeedsLayout]; // swap the label to "Loading…" right away

    __weak __typeof__(self) weakSelf = self;
    ApolloDevvitFetchEntrypoint(link, ^(NSDictionary *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            objc_setAssociatedObject((id)strongSelf, kApolloDevvitLoadingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!result) {
                objc_setAssociatedObject((id)strongSelf, kApolloDevvitTappedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [(ASDisplayNode *)(id)strongSelf setNeedsLayout];
                return;
            }
            objc_setAssociatedObject((id)strongSelf, kApolloDevvitStateKey, result, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [(ASDisplayNode *)(id)strongSelf invalidateCalculatedLayout];
            [(ASDisplayNode *)(id)strongSelf setNeedsLayout];
            ApolloDevvitForceHeaderRemeasure((id)strongSelf);
        });
    });
}

- (id)layoutSpecThatFits:(struct ApolloDevvitSizeRange)constrainedSize {
    id originalSpec = %orig;
    if (!sEnableDevvitEmbeds || !ApolloDevvitAvailable()) return originalSpec;

    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    if (!ApolloDevvitLinkIsPlaceholder(link)) return originalSpec;

    NSDictionary *state = objc_getAssociatedObject((id)self, kApolloDevvitStateKey);
    BOOL embeddable = state ? [state[@"embeddable"] boolValue] : YES; // unresolved yet -> optimistic tap target
    if (state && !embeddable) return originalSpec; // confirmed not embeddable — keep the original placeholder+link

    BOOL loading = !state && [objc_getAssociatedObject((id)self, kApolloDevvitLoadingKey) boolValue];
    id replacement = ApolloDevvitEmbedSpec(state ?: @{}, constrainedSize.max.width, (id)self, loading, link.fullName);
    if (!replacement) return originalSpec;

    id newRoot = ApolloDevvitPlaceReplacementPreservingRoot(originalSpec, replacement);
    if (!newRoot) {
        ApolloLog(@"[DevvitEmbed][UI] no MarkdownNode body found in header layout; leaving placeholder");
        return originalSpec;
    }
    return newRoot;
}

%end

#pragma mark - CommentsViewController hook (real teardown trigger)

static const void *kApolloDevvitPoppingKey = &kApolloDevvitPoppingKey;

// -didExitDisplayState/-dealloc on the cell (above) never fire for a normal
// swipe-back, because Apollo's own forward-swipe feature deliberately keeps
// popped comments screens (and their view hierarchies) alive — see the note
// on ApolloDevvitTrackedCells(). The real, reliable "user navigated away"
// signal is the navigation controller actually popping this VC, mirrored
// here on the same isMovingFromParentViewController + viewWillDisappear: /
// viewDidDisappear: pairing ApolloVideoUnmute.xm already uses for the
// equivalent problem (there, protecting audio state across the same
// transition; here, tearing down the embed webview).
%hook _TtC6Apollo22CommentsViewController

- (void)viewWillDisappear:(BOOL)animated {
    BOOL isPopping = [(UIViewController *)self isMovingFromParentViewController];
    objc_setAssociatedObject((id)self, kApolloDevvitPoppingKey, @(isPopping), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[DevvitEmbed][lifecycle] CommentsVC %p viewWillDisappear isPopping=%d", self, isPopping);
    %orig;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    BOOL isPopping = [objc_getAssociatedObject((id)self, kApolloDevvitPoppingKey) boolValue];
    objc_setAssociatedObject((id)self, kApolloDevvitPoppingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger trackedCount = ApolloDevvitTrackedCells().count;
    ApolloLog(@"[DevvitEmbed][lifecycle] CommentsVC %p viewDidDisappear isPopping=%d trackedCells=%lu",
              self, isPopping, (unsigned long)trackedCount);
    if (!isPopping) return; // covered by a pushed screen (e.g. fullscreen media), not actually leaving

    for (id cell in [ApolloDevvitTrackedCells() copy]) {
        UIViewController *owner = ApolloDevvitEnclosingViewController(cell);
        BOOL hasCachedNode = objc_getAssociatedObject(cell, kApolloDevvitEmbedNodeKey) != nil;
        ApolloLog(@"[DevvitEmbed][lifecycle]   tracked cell %p owner=%p (self=%p match=%d) hasCachedNode=%d",
                  cell, owner, self, owner == (id)self, hasCachedNode);
        if (owner == (id)self) {
            ApolloDevvitTeardownEmbedNode(cell);
        }
    }
}

%end

%ctor {
    ApolloLog(@"[DevvitEmbed] loaded; enabled=%d autoLoad=%d", sEnableDevvitEmbeds, sDevvitEmbedsAutoLoad);
}
