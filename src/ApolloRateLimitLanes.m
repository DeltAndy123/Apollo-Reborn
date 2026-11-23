#import "ApolloRateLimitLanes.h"

#include <math.h>

#pragma mark - Header parsing

// A header Reddit sends as a decimal string ("14", "86.0"). NAN when absent or
// not a number.
static double ApolloRateLimitHeaderValue(NSHTTPURLResponse *response, NSString *name) {
    NSString *value = [response valueForHTTPHeaderField:name];
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NAN;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    double number = 0;
    return ([scanner scanDouble:&number] && scanner.isAtEnd) ? number : NAN;
}

ApolloRateLimitHeaders ApolloRateLimitHeadersFromResponse(NSHTTPURLResponse *response) {
    ApolloRateLimitHeaders headers = { NAN, NAN, NAN };
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return headers;
    headers.used = ApolloRateLimitHeaderValue(response, @"x-ratelimit-used");
    headers.remaining = ApolloRateLimitHeaderValue(response, @"x-ratelimit-remaining");
    headers.reset = ApolloRateLimitHeaderValue(response, @"x-ratelimit-reset");
    return headers;
}

BOOL ApolloRateLimitHeadersAny(ApolloRateLimitHeaders headers) {
    return !isnan(headers.used) || !isnan(headers.remaining) || !isnan(headers.reset);
}

static NSString *ApolloRateLimitNumber(double value) {
    if (isnan(value)) return @"?";
    if (fabs(value - round(value)) < 0.05) return [NSString stringWithFormat:@"%.0f", value];
    return [NSString stringWithFormat:@"%.1f", value];
}

NSString *ApolloRateLimitHeadersDescription(ApolloRateLimitHeaders headers) {
    if (!ApolloRateLimitHeadersAny(headers)) return @"no rate-limit headers";
    NSString *text = [NSString stringWithFormat:@"used %@, remaining %@", ApolloRateLimitNumber(headers.used),
                      ApolloRateLimitNumber(headers.remaining)];
    if (!isnan(headers.used) && !isnan(headers.remaining)) {
        text = [text stringByAppendingFormat:@" (of %@)", ApolloRateLimitNumber(headers.used + headers.remaining)];
    }
    if (!isnan(headers.reset)) text = [text stringByAppendingFormat:@", resets in %@s", ApolloRateLimitNumber(headers.reset)];
    return text;
}

#pragma mark - Lanes

NSString *ApolloRateLimitLaneName(ApolloRateLimitLane lane) {
    switch (lane) {
        case ApolloRateLimitLaneCookieJSON: return @"Cookie .json";
        case ApolloRateLimitLaneWebPage: return @"Website pages";
        case ApolloRateLimitLaneOAuth: return @"OAuth (oauth.reddit.com)";
        case ApolloRateLimitLaneGraphQL: return @"GraphQL";
        default: return @"?";
    }
}

static BOOL ApolloRateLimitIsRedditWebHost(NSString *host) {
    return [host isEqualToString:@"www.reddit.com"] || [host isEqualToString:@"old.reddit.com"] ||
           [host isEqualToString:@"api.reddit.com"] || [host isEqualToString:@"sh.reddit.com"] ||
           [host isEqualToString:@"reddit.com"];
}

ApolloRateLimitLane ApolloRateLimitLaneForRequest(NSURLRequest *request) {
    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return ApolloRateLimitLaneNone;
    NSString *path = url.path ?: @"/";

    if ([host isEqualToString:@"gql-fed.reddit.com"] || [host isEqualToString:@"cf.gql-fed.reddit.com"] ||
        [host isEqualToString:@"gql.reddit.com"]) {
        return ApolloRateLimitLaneGraphQL;
    }
    if ([host isEqualToString:@"oauth.reddit.com"]) return ApolloRateLimitLaneOAuth;
    if (!ApolloRateLimitIsRedditWebHost(host)) return ApolloRateLimitLaneNone;
    if ([path hasPrefix:@"/svc/shreddit/graphql"]) return ApolloRateLimitLaneGraphQL;

    // A signed-out fetch (no cookie) isn't counted against the account, so it
    // says nothing about its budget.
    if ([request valueForHTTPHeaderField:@"Cookie"].length == 0) return ApolloRateLimitLaneNone;
    // The keyless transport's reads and writes: ".json" listings and /api/
    // endpoints. Everything else with the cookie is a website page or an
    // HTML fragment.
    if ([path rangeOfString:@".json"].location != NSNotFound || [path hasPrefix:@"/api/"] ||
        ([path hasPrefix:@"/r/"] && [path rangeOfString:@"/api/"].location != NSNotFound)) {
        return ApolloRateLimitLaneCookieJSON;
    }
    return ApolloRateLimitLaneWebPage;
}

#pragma mark - Recording

@interface ApolloRateLimitLaneRecord : NSObject
@property (nonatomic) NSUInteger responses;
@property (nonatomic) NSUInteger withHeaders;
@property (nonatomic) ApolloRateLimitHeaders latest;
@property (nonatomic) NSTimeInterval seenAt;
@property (nonatomic) NSUInteger count429;
@property (nonatomic) NSTimeInterval last429At;
@property (nonatomic) NSTimeInterval lastResponseAt;
@end

@implementation ApolloRateLimitLaneRecord
@end

// Lowercased account ("" for none) → lane records (NSArray, one per lane).
static NSMutableDictionary<NSString *, NSArray<ApolloRateLimitLaneRecord *> *> *sApolloRateLimitRecords;

static NSObject *ApolloRateLimitLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *ApolloRateLimitAccountKey(NSString *account) {
    if (![account isKindOfClass:[NSString class]]) return @"";
    return account.lowercaseString ?: @"";
}

// Caller holds the lock.
static NSArray<ApolloRateLimitLaneRecord *> *ApolloRateLimitRecordsForKey(NSString *key, BOOL create) {
    NSArray *records = sApolloRateLimitRecords[key];
    if (records || !create) return records;
    NSMutableArray *fresh = [NSMutableArray arrayWithCapacity:ApolloRateLimitLaneCount];
    for (NSInteger i = 0; i < ApolloRateLimitLaneCount; i++) {
        ApolloRateLimitLaneRecord *record = [ApolloRateLimitLaneRecord new];
        record.latest = (ApolloRateLimitHeaders){ NAN, NAN, NAN };
        [fresh addObject:record];
    }
    if (!sApolloRateLimitRecords) sApolloRateLimitRecords = [NSMutableDictionary dictionary];
    sApolloRateLimitRecords[key] = fresh;
    return fresh;
}

void ApolloRateLimitRecordResponse(NSURLRequest *request, NSURLResponse *response, NSString *account) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return;
    ApolloRateLimitLane lane = ApolloRateLimitLaneForRequest(request);
    if (lane == ApolloRateLimitLaneNone) return;
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    ApolloRateLimitHeaders headers = ApolloRateLimitHeadersFromResponse(http);
    BOOL any = ApolloRateLimitHeadersAny(headers);
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    @synchronized (ApolloRateLimitLock()) {
        ApolloRateLimitLaneRecord *record = ApolloRateLimitRecordsForKey(ApolloRateLimitAccountKey(account), YES)[lane];
        record.responses += 1;
        record.lastResponseAt = now;
        if (any) {
            record.withHeaders += 1;
            record.latest = headers;
            record.seenAt = now;
        }
        if (http.statusCode == 429) {
            record.count429 += 1;
            record.last429At = now;
        }
    }
}

NSArray<NSDictionary<NSString *, id> *> *ApolloRateLimitLaneSnapshot(NSString *account) {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:ApolloRateLimitLaneCount];
    @synchronized (ApolloRateLimitLock()) {
        NSArray<ApolloRateLimitLaneRecord *> *records = ApolloRateLimitRecordsForKey(ApolloRateLimitAccountKey(account), NO);
        for (NSInteger lane = 0; lane < ApolloRateLimitLaneCount; lane++) {
            ApolloRateLimitLaneRecord *record = records[lane];
            NSMutableDictionary *row = [@{ @"lane": @(lane),
                                           @"name": ApolloRateLimitLaneName((ApolloRateLimitLane)lane),
                                           @"responses": @(record.responses),
                                           @"withHeaders": @(record.withHeaders),
                                           @"seenAt": @(record.seenAt),
                                           @"count429": @(record.count429),
                                           @"last429At": @(record.last429At),
                                           @"lastResponseAt": @(record.lastResponseAt) } mutableCopy];
            if (record && !isnan(record.latest.used)) row[@"used"] = @(record.latest.used);
            if (record && !isnan(record.latest.remaining)) row[@"remaining"] = @(record.latest.remaining);
            if (record && !isnan(record.latest.reset)) row[@"reset"] = @(record.latest.reset);
            [rows addObject:row];
        }
    }
    return rows;
}

static NSString *ApolloRateLimitAgo(NSTimeInterval at, NSTimeInterval now) {
    NSTimeInterval ago = MAX(0, now - at);
    if (ago < 60) return [NSString stringWithFormat:@"%.0fs ago", floor(ago)];
    if (ago < 3600) return [NSString stringWithFormat:@"%.0f min ago", floor(ago / 60.0)];
    return [NSString stringWithFormat:@"%.0f h ago", floor(ago / 3600.0)];
}

NSString *ApolloRateLimitLaneDetail(NSDictionary<NSString *, id> *row) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSUInteger responses = [row[@"responses"] unsignedIntegerValue];
    NSUInteger withHeaders = [row[@"withHeaders"] unsignedIntegerValue];
    NSUInteger count429 = [row[@"count429"] unsignedIntegerValue];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (responses == 0) {
        [parts addObject:@"no replies yet"];
    } else if (withHeaders == 0) {
        [parts addObject:[NSString stringWithFormat:@"no rate-limit headers seen (%lu replies)", (unsigned long)responses]];
    } else {
        ApolloRateLimitHeaders latest = {
            row[@"used"] ? [row[@"used"] doubleValue] : NAN,
            row[@"remaining"] ? [row[@"remaining"] doubleValue] : NAN,
            NAN,
        };
        NSString *text = ApolloRateLimitHeadersDescription(latest);
        NSTimeInterval seenAt = [row[@"seenAt"] doubleValue];
        if (row[@"reset"]) {
            // Count the reset down from when the answer arrived.
            double left = [row[@"reset"] doubleValue] - (now - seenAt);
            text = [text stringByAppendingString:left > 0 ? [NSString stringWithFormat:@", resets in %.0fs", ceil(left)]
                                                          : @", that window has ended"];
        }
        [parts addObject:[NSString stringWithFormat:@"%@ (seen %@; %lu of %lu replies had headers)", text,
                          ApolloRateLimitAgo(seenAt, now), (unsigned long)withHeaders, (unsigned long)responses]];
    }
    if (count429 > 0) {
        [parts addObject:[NSString stringWithFormat:@"%lu× HTTP 429, last %@", (unsigned long)count429,
                          ApolloRateLimitAgo([row[@"last429At"] doubleValue], now)]];
    } else if (responses > 0) {
        [parts addObject:@"no 429s"];
    }
    return [parts componentsJoinedByString:@"; "];
}

NSArray<NSString *> *ApolloRateLimitLaneSummaryLines(NSString *account) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *row in ApolloRateLimitLaneSnapshot(account)) {
        [lines addObject:[NSString stringWithFormat:@"  %@: %@", row[@"name"], ApolloRateLimitLaneDetail(row)]];
    }
    return lines;
}

#pragma mark - Budget check result

static NSString *sApolloRateLimitBudgetCheckResult;

void ApolloRateLimitSetBudgetCheckResult(NSString *result) {
    @synchronized (ApolloRateLimitLock()) {
        sApolloRateLimitBudgetCheckResult = [result copy];
    }
}

NSString *ApolloRateLimitBudgetCheckResult(void) {
    @synchronized (ApolloRateLimitLock()) {
        return sApolloRateLimitBudgetCheckResult;
    }
}
