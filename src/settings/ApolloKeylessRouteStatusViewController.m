#import "settings/ApolloKeylessRouteStatusViewController.h"

#import "ApolloCommon.h"
#import "ApolloToast.h"
#import "ApolloRateLimitLanes.h"
#import "ApolloWebJSON.h"
#import "ApolloWebJSONRoutes.h"
#import "ApolloWebJSONRouteUpdates.h"
#import "ApolloWebSessionStore.h"
#import "ApolloState.h"

static NSString *ApolloRouteStatusAgo(NSTimeInterval at) {
    if (at <= 0) return nil;
    NSTimeInterval ago = MAX(0, [NSDate timeIntervalSinceReferenceDate] - at);
    if (ago < 60) return @"just now";
    if (ago < 3600) return [NSString stringWithFormat:@"%.0f min ago", floor(ago / 60.0)];
    return [NSString stringWithFormat:@"%.0f h ago", floor(ago / 3600.0)];
}

@implementation ApolloKeylessRouteStatusViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Routes";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(refresh)];
    // A report's log then shows what the user was looking at.
    ApolloLog(@"[WebJSON] %@", ApolloWebJSONRouteStatusSummary());
}

- (void)refresh {
    [self rebuildForm];
}

// A read-only cell: a title and a wrapping secondary line.
- (ApolloSettingsRow *)infoRowWithID:(NSString *)rowID title:(NSString *)title detail:(nullable NSString *)detail {
    __weak typeof(self) weakSelf = self;
    return [ApolloSettingsRow customRowWithID:rowID
                                         cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_RouteStatus_Info"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_RouteStatus_Info"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.numberOfLines = 0;
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        }
        cell.textLabel.text = title;
        cell.detailTextLabel.text = detail;
        [weakSelf apollo_applyPrimaryTextColorToCell:cell];
        return cell;
    }
                                     onSelect:nil];
}

- (NSString *)detailForEndpoint:(NSDictionary *)endpoint {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger using = [endpoint[@"using"] integerValue];
    if ([endpoint[@"allCooling"] boolValue]) {
        [lines addObject:@"Every route is blocked right now"];
    } else if (using >= 0) {
        [lines addObject:[@"Using " stringByAppendingString:ApolloWebJSONRouteName((ApolloWebJSONRoute)using)]];
    }
    for (NSDictionary *route in endpoint[@"routes"]) {
        NSString *line = [NSString stringWithFormat:@"%@: %@ ok, %@ blocked",
                          ApolloWebJSONRouteName((ApolloWebJSONRoute)[route[@"route"] integerValue]), route[@"ok"], route[@"blocked"]];
        NSTimeInterval cooling = [route[@"cooldownRemaining"] doubleValue];
        NSString *lastOk = ApolloRouteStatusAgo([route[@"lastOkAt"] doubleValue]);
        if (cooling > 0) line = [line stringByAppendingFormat:@", skipped for %.0f more min", ceil(cooling / 60.0)];
        else if (lastOk) line = [line stringByAppendingFormat:@", last ok %@", lastOk];
        [lines addObject:line];
    }
    if ([endpoint[@"remote"] boolValue]) [lines addObject:@"Order from keyless-routes.json"];
    return [lines componentsJoinedByString:@"\n"];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    NSString *account = ApolloActiveWebSessionUsername();
    NSMutableArray<ApolloSettingsSection *> *sections = [NSMutableArray array];

    NSMutableArray<ApolloSettingsRow *> *endpointRows = [NSMutableArray array];
    for (NSDictionary *endpoint in ApolloWebJSONRouteStatusEndpoints()) {
        [endpointRows addObject:[self infoRowWithID:[@"routes.endpoint." stringByAppendingString:endpoint[@"key"]]
                                              title:endpoint[@"key"]
                                             detail:[self detailForEndpoint:endpoint]]];
    }
    NSString *who = account.length ? [NSString stringWithFormat:@"u/%@", account] : @"the active account";
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:@"Routes"
                                         footer:[NSString stringWithFormat:@"Reddit blocks these for API-key-free accounts at their usual address, so they can go by more than one. Counts are for %@ since Apollo opened. A route that's blocked 3 times in a row is skipped for an hour.", who]
                                           rows:endpointRows]];

    [sections addObject:[self rateLimitSectionForAccount:account who:who]];

    NSMutableArray<ApolloSettingsRow *> *blockedRows = [NSMutableArray array];
    for (NSDictionary *row in ApolloWebJSONRouteStatusBlockedPaths()) {
        NSString *lastBlocked = ApolloRouteStatusAgo([row[@"lastBlockedAt"] doubleValue]);
        [blockedRows addObject:[self infoRowWithID:[@"routes.blocked." stringByAppendingString:row[@"pattern"]]
                                             title:row[@"pattern"]
                                            detail:[NSString stringWithFormat:@"%@ blocked, %@ ok%@", row[@"blocked"], row[@"ok"],
                                                    lastBlocked ? [@", last blocked " stringByAppendingString:lastBlocked] : @""]]];
    }
    if (blockedRows.count == 0) {
        [blockedRows addObject:[self infoRowWithID:@"routes.blocked.none" title:@"None since Apollo opened" detail:nil]];
    }
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:@"Blocked Without Another Route"
                                         footer:@"Requests Reddit refused with its block page that have no other route. If one keeps failing, copy the summary into a bug report."
                                           rows:blockedRows]];

    NSDictionary *updates = ApolloWebJSONRouteUpdatesStatus();
    __weak typeof(self) weakSelf = self;
    ApolloSettingsRow *updatesState =
        [ApolloSettingsRow switchRowWithID:@"routes.updates.state"
                                     title:@"Use Route Updates"
                                      isOn:^BOOL { return sKeylessRouteUpdates; }
                                  onToggle:^(UISwitch *sender) {
            ApolloWebJSONRouteUpdatesSetEnabled(sender.isOn);
            // The result line and the routes in use change with it.
            [weakSelf rebuildForm];
        }];
    ApolloSettingsRow *updatesChecked =
        [ApolloSettingsRow valueRowWithID:@"routes.updates.checked" title:@"Last Checked"
                                   detail:^NSString *{ return updates[@"lastChecked"]; }
                                 onSelect:nil];
    ApolloSettingsRow *updatesResult =
        [self infoRowWithID:@"routes.updates.result" title:@"Result" detail:updates[@"result"]];
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:@"Route Updates"
                                         footer:@"When Reddit blocks an address API-key-free accounts use, Apollo Reborn can switch to another reddit.com address from a list kept in its GitHub repository (keyless-routes.json), checked every 15 minutes while Apollo is open. Off uses only the addresses built into this version."
                                           rows:@[ updatesState, updatesChecked, updatesResult ]]];

    ApolloSettingsRow *copy = [ApolloSettingsRow buttonRowWithID:@"routes.copy" title:@"Copy Summary" action:^{
        [weakSelf copySummary];
    }];
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Copies this screen as text to paste into a bug report. Nothing here is sent anywhere unless you send it."
                                           rows:@[ copy ]]];
    return sections;
}

// What Reddit's x-ratelimit-* headers said per kind of request, recorded from
// answers the app already gets (ApolloRateLimitLanes.h).
- (ApolloSettingsSection *)rateLimitSectionForAccount:(NSString *)account who:(NSString *)who {
    NSMutableArray<ApolloSettingsRow *> *rows = [NSMutableArray array];
    for (NSDictionary *lane in ApolloRateLimitLaneSnapshot(account)) {
        [rows addObject:[self infoRowWithID:[NSString stringWithFormat:@"routes.ratelimit.%@", lane[@"lane"]]
                                      title:lane[@"name"]
                                     detail:ApolloRateLimitLaneDetail(lane)]];
    }
    NSArray<NSString *> *cidLines = ApolloWebJSONTokenClientIDLines(account);
    [rows addObject:[self infoRowWithID:@"routes.ratelimit.cid" title:@"Token Client ID"
                                 detail:cidLines.count ? [cidLines componentsJoinedByString:@"\n"] : @"No web session"]];
#if APOLLO_DEV_BUILD
    __weak typeof(self) weakSelf = self;
    [rows addObject:[ApolloSettingsRow buttonRowWithID:@"routes.ratelimit.check" title:@"Check GraphQL Budget (Dev)" action:^{
        [weakSelf runGraphQLBudgetCheck];
    }]];
    NSString *check = ApolloRateLimitBudgetCheckResult();
    if (check.length) {
        [rows addObject:[self infoRowWithID:@"routes.ratelimit.checkResult" title:@"Last Check" detail:check]];
    }
#endif
    return [ApolloSettingsSection sectionWithTitle:@"Rate Limits"
                                            footer:[NSString stringWithFormat:@"The latest x-ratelimit headers Reddit sent %@ for each kind of request since Apollo opened. Nothing extra is sent to get them. \"No rate-limit headers seen\" means Reddit answered but didn't report a limit. Tap refresh to update.", who]
                                              rows:rows];
}

#if APOLLO_DEV_BUILD
#pragma mark - GraphQL budget check (dev builds only)

// One request and its answer's headers, for the check below.
typedef void (^ApolloBudgetCheckStep)(NSInteger status, ApolloRateLimitHeaders headers, NSString *error, NSData *body);

static void ApolloBudgetCheckSend(NSURLRequest *request, ApolloBudgetCheckStep done) {
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        ApolloRateLimitHeaders headers = ApolloRateLimitHeadersFromResponse(http);
        dispatch_async(dispatch_get_main_queue(), ^{
            done(http.statusCode, headers, error.localizedDescription, data);
        });
    }] resume];
}

// The account's own /api/me.json, sent the way Apollo's reads are: to
// oauth.reddit.com with the account's placeholder bearer, which the request
// rewrite turns into a cookie .json request on www.reddit.com.
static NSURLRequest *ApolloBudgetCheckJSONRequest(NSString *account) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth.reddit.com/api/me.json"]];
    [request setValue:[@"bearer " stringByAppendingString:ApolloWebJSONSyntheticBearerTokenForUsername(account)]
   forHTTPHeaderField:@"Authorization"];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 15;
    return request;
}

static NSURLRequest *ApolloBudgetCheckGraphQLRequest(NSString *bearer) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/"]];
    request.HTTPMethod = @"POST";
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 15;
    request.HTTPShouldHandleCookies = NO;
    NSDictionary *body = @{
        @"operationName": @"GetAccount",
        @"variables": @{ @"includePremiumAvatarTreatment": @NO, @"includeBrandToolsStatus": @NO,
                         @"includePostFlairTemplates": @NO, @"includeRedditHandleInfo": @NO,
                         @"includeVerificationStatus": @NO, @"includeHumanVerificationActionNeeded": @NO },
        @"extensions": @{ @"persistedQuery": @{ @"version": @1,
                                                @"sha256Hash": @"b5ad6715b375f0a4c5347979f1237364025b78028b90a8a618e9b1e8036b26ef" } },
    };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"https://www.reddit.com" forHTTPHeaderField:@"Origin"];
    return request;
}

static NSString *ApolloBudgetCheckLine(NSString *label, NSInteger status, ApolloRateLimitHeaders headers, NSString *error) {
    if (error.length) return [NSString stringWithFormat:@"%@: failed (%@)", label, error];
    return [NSString stringWithFormat:@"%@: HTTP %ld, %@", label, (long)status, ApolloRateLimitHeadersDescription(headers)];
}

// GraphQL answers HTTP 200 even when the query failed, so say whether it
// returned the account or an error (its message only; no account data).
static NSString *ApolloBudgetCheckGraphQLOutcome(NSData *body) {
    id json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return @", body not JSON";
    id errors = json[@"errors"];
    if ([errors isKindOfClass:[NSArray class]] && [errors count] > 0) {
        id first = [errors firstObject];
        id message = [first isKindOfClass:[NSDictionary class]] ? first[@"message"] : nil;
        return [NSString stringWithFormat:@", query error: %@", [message isKindOfClass:[NSString class]] ? message : @"?"];
    }
    id data = json[@"data"];
    return ([data isKindOfClass:[NSDictionary class]] && [data count] > 0) ? @", returned data" : @", returned no data";
}

// Whether the GraphQL call counted against the .json budget: the second .json
// reports its own request too, so "used" moving by 1 means GraphQL wasn't
// counted there, by 2 or more that it was (or that something else was sent
// meanwhile).
static NSString *ApolloBudgetCheckVerdict(ApolloRateLimitHeaders first, ApolloRateLimitHeaders second) {
    if (isnan(first.used) || isnan(second.used)) {
        return @"Verdict: .json reported no used count, so this can't tell whether GraphQL shares its budget.";
    }
    double moved = second.used - first.used;
    if (moved < 0) return @"Verdict: .json's window reset during the check; run it again.";
    if (moved < 1.5) return [NSString stringWithFormat:@"Verdict: separate budgets (.json used moved by %.0f, its own request).", moved];
    return [NSString stringWithFormat:@"Verdict: GraphQL looks counted against .json (used moved by %.0f; 1 is the second .json itself). Other requests in flight can also move it; run it again on a quiet screen to confirm.", moved];
}

- (void)runGraphQLBudgetCheck {
    NSString *account = ApolloActiveWebSessionUsername();
    if (account.length == 0) {
        ApolloRateLimitSetBudgetCheckResult(@"No API-Key-Free account is active.");
        [self rebuildForm];
        return;
    }
    ApolloShowToastWithStyle(@"Checking GraphQL Budget", @"Sending 3 requests", ApolloToastStyleSuccess, nil);
    ApolloLog(@"[RateLimits] GraphQL budget check started");
    __weak typeof(self) weakSelf = self;
    void (^finish)(NSString *) = ^(NSString *result) {
        ApolloRateLimitSetBudgetCheckResult(result);
        ApolloLog(@"[RateLimits] GraphQL budget check: %@", result);
        [weakSelf rebuildForm];
    };
    ApolloBudgetCheckSend(ApolloBudgetCheckJSONRequest(account), ^(NSInteger status1, ApolloRateLimitHeaders json1, NSString *error1, __unused NSData *body1) {
        NSString *line1 = ApolloBudgetCheckLine(@".json #1", status1, json1, error1);
        ApolloWebJSONDevDesktopWebBearer(account, ^(NSString *bearer, NSString *source) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (bearer.length == 0) {
                    finish([NSString stringWithFormat:@"%@\nGraphQL: not sent (%@)", line1, source]);
                    return;
                }
                ApolloBudgetCheckSend(ApolloBudgetCheckGraphQLRequest(bearer), ^(NSInteger statusG, ApolloRateLimitHeaders gql, NSString *errorG, NSData *bodyG) {
                    NSString *lineG = [ApolloBudgetCheckLine([NSString stringWithFormat:@"GraphQL GetAccount (%@)", source], statusG, gql, errorG)
                                       stringByAppendingString:errorG.length ? @"" : ApolloBudgetCheckGraphQLOutcome(bodyG)];
                    ApolloBudgetCheckSend(ApolloBudgetCheckJSONRequest(account), ^(NSInteger status2, ApolloRateLimitHeaders json2, NSString *error2, __unused NSData *body2) {
                        NSString *line2 = ApolloBudgetCheckLine(@".json #2", status2, json2, error2);
                        finish([@[ line1, lineG, line2, ApolloBudgetCheckVerdict(json1, json2) ] componentsJoinedByString:@"\n"]);
                    });
                });
            });
        });
    });
}
#endif

- (void)copySummary {
    NSString *summary = ApolloWebJSONRouteStatusSummary();
    UIPasteboard.generalPasteboard.string = summary;
    ApolloLog(@"[WebJSON] %@", summary);
    ApolloShowToastWithStyle(@"Summary Copied", @"Paste it into a bug report", ApolloToastStyleSuccess, nil);
}

@end
