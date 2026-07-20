#import "DevvitEmbedSettingsViewController.h"

#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloDevvitSettingsRow) {
    ApolloDevvitSettingsRowEnabled = 0,
    ApolloDevvitSettingsRowAutoLoad,
    ApolloDevvitSettingsRowCount,
};

@implementation DevvitEmbedSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Interactive Posts";
}

#pragma mark - Helpers

- (UITableViewCell *)switchCellWithLabel:(NSString *)label
                                       on:(BOOL)on
                                  enabled:(BOOL)enabled
                                   action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = on;
    toggle.enabled = enabled;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return ApolloDevvitSettingsRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Some posts (polls, games, and other interactive apps) show a "
            "\"not supported\" placeholder link instead of rendering. This shows "
            "a live version inline under the title in the comments view instead "
            "(not in the feed). Load Automatically starts loading as soon as the "
            "post opens; when off, a tap target appears first instead.\n\n"
            "This relies on undocumented Reddit internals and may occasionally stop "
            "working for a given post if Reddit changes them — the original "
            "placeholder and link are always shown as a fallback.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.row) {
        case ApolloDevvitSettingsRowEnabled:
            return [self switchCellWithLabel:@"Show Interactive Post Embeds"
                                           on:sEnableDevvitEmbeds
                                      enabled:YES
                                       action:@selector(enabledSwitchToggled:)];
        case ApolloDevvitSettingsRowAutoLoad:
        default:
            return [self switchCellWithLabel:@"Load Automatically"
                                           on:sDevvitEmbedsAutoLoad
                                      enabled:sEnableDevvitEmbeds
                                       action:@selector(autoLoadSwitchToggled:)];
    }
}

#pragma mark - Actions

- (void)enabledSwitchToggled:(UISwitch *)sender {
    sEnableDevvitEmbeds = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableDevvitEmbeds forKey:UDKeyEnableDevvitEmbeds];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:ApolloDevvitSettingsRowAutoLoad inSection:0]]
                           withRowAnimation:UITableViewRowAnimationNone];
}

- (void)autoLoadSwitchToggled:(UISwitch *)sender {
    sDevvitEmbedsAutoLoad = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sDevvitEmbedsAutoLoad forKey:UDKeyDevvitEmbedsAutoLoad];
}

@end
