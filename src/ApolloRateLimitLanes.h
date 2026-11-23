#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reddit's rate-limit headers, per kind of request ("lane"), as the answers the
// tweak already sees report them. Nothing here sends a request.
//
// Reddit answers some requests with
//   x-ratelimit-used        units spent this window
//   x-ratelimit-remaining   units left
//   x-ratelimit-reset       seconds until the window ends
// but which requests carry them, and the budget they report, varies by kind of
// request and by account. The Routes screen shows the latest report per lane so
// a tester can paste what Reddit tells their own account. A lane that has
// answers but never a header is a finding in itself.
//
// Foundation-only. Thread-safe.

#ifdef __cplusplus
extern "C" {
#endif

// The three headers off one answer. Each value is NAN when the header is
// missing or isn't a number ("14", "86.0" parse).
typedef struct {
    double used;
    double remaining;
    double reset;
} ApolloRateLimitHeaders;

ApolloRateLimitHeaders ApolloRateLimitHeadersFromResponse(NSHTTPURLResponse *_Nullable response);

// YES when at least one of the three is present.
BOOL ApolloRateLimitHeadersAny(ApolloRateLimitHeaders headers);

// "used 14, remaining 86, resets in 312s"; "no rate-limit headers" when none.
NSString *ApolloRateLimitHeadersDescription(ApolloRateLimitHeaders headers);

typedef NS_ENUM(NSInteger, ApolloRateLimitLane) {
    ApolloRateLimitLaneNone = -1,
    ApolloRateLimitLaneCookieJSON = 0, // cookie-authenticated .json / /api/ on www/old/api.reddit.com
    ApolloRateLimitLaneWebPage,        // cookie-authenticated website pages and /svc/shreddit/ fragments
    ApolloRateLimitLaneOAuth,          // oauth.reddit.com (API keys, or a keyless web bearer)
    ApolloRateLimitLaneGraphQL,        // gql-fed / cf.gql-fed / gql.reddit.com, /svc/shreddit/graphql
    ApolloRateLimitLaneCount
};

NSString *ApolloRateLimitLaneName(ApolloRateLimitLane lane);

// The lane `request` (as sent) belongs to, or ApolloRateLimitLaneNone for
// anything that isn't a Reddit request worth counting.
ApolloRateLimitLane ApolloRateLimitLaneForRequest(NSURLRequest *_Nullable request);

// Records the answer to `request` under `account` (nil or "" for an account
// with no web session). Called from the task-completion chokepoint for every
// finished task; returns at once for non-Reddit requests. Any thread.
void ApolloRateLimitRecordResponse(NSURLRequest *_Nullable request, NSURLResponse *_Nullable response,
                                   NSString *_Nullable account);

// One dictionary per lane, in lane order, for `account` since launch:
// "lane" (NSNumber), "name", "responses", "withHeaders", "used", "remaining",
// "reset" (NSNumber, absent when never seen), "seenAt" (reference-date seconds
// of the latest answer with headers, 0 if none), "count429", "last429At" (0 if
// none), "lastResponseAt".
NSArray<NSDictionary<NSString *, id> *> *ApolloRateLimitLaneSnapshot(NSString *_Nullable account);

// One line per lane for the copied summary ("  GraphQL: used 3, remaining
// 747, resets in 120s (seen 2 min ago); 0× 429"), without a heading.
NSArray<NSString *> *ApolloRateLimitLaneSummaryLines(NSString *_Nullable account);

// The detail line for one snapshot row, shared by the screen and the summary.
NSString *ApolloRateLimitLaneDetail(NSDictionary<NSString *, id> *row);

// The result of the last "Check GraphQL budget" run (dev builds), one line,
// or nil. Included in the copied summary. Any thread.
void ApolloRateLimitSetBudgetCheckResult(NSString *_Nullable result);
NSString *_Nullable ApolloRateLimitBudgetCheckResult(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
