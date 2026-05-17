// ApolloTweetBuddy.xm
// Intercepts Apollo's TweetBuddy network requests to apollogur.download (now defunct)
// and replaces them with live fetches against X/Twitter's internal GraphQL API.
//
// Flow:
//   1. Hook NSURLSessionConfiguration.defaultSessionConfiguration to inject
//      ApolloTweetProtocol into every session TweetBuddy creates.
//   2. ApolloTweetProtocol intercepts GET .../api/tweet/{id} requests.
//   3. Fetch a guest token by scraping https://x.com/ HTML (cached for 9000s).
//   4. Call X's internal TweetResultByRestId GraphQL endpoint.
//   5. Transform the GraphQL response to the v1.1 shape Apollo's JSON parser expects.
//   6. Deliver the synthetic response back to TweetBuddy's completion handler.

#import <Foundation/Foundation.h>
#import "ApolloCommon.h"

// ─── Constants ────────────────────────────────────────────────────────────────

static NSString *const kApolloTweetBaseURL    = @"https://apollogur.download/api/tweet/";
static NSString *const kXHomepageURL          = @"https://x.com/";
static NSString *const kXGraphQLURL           = @"https://api.x.com/graphql/zy39CwTyYhU-_0LP7dljjg/TweetResultByRestId";
// Public bearer token baked into X's web client JS — same for all guest sessions.
static NSString *const kXBearerToken          = @"Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";
// x.com sets gt= via inline JS, not Set-Cookie. Token lifetime is ~2.5 hours.
static const NSTimeInterval kGuestTokenMaxAge = 9000.0;
// Mark our own internal requests so the protocol doesn't intercept them.
static NSString *const kHandledKey            = @"ApolloTweetProtocolHandled";

// ─── Guest Token Cache ────────────────────────────────────────────────────────

static NSString        *sGuestToken     = nil;
static NSDate          *sTokenFetchDate = nil;
// Serialises token reads/writes and prevents concurrent homepage fetches.
static dispatch_queue_t sTokenQueue;

// ─── JSON Transform ───────────────────────────────────────────────────────────

// Maps the GraphQL response shape to the Twitter v1.1 subset Apollo parses:
//   full_text, user.{name, screen_name, profile_image_url_https, verified}, entities
static NSDictionary *ATBTransformResult(NSDictionary *result) {
    NSDictionary *legacy     = result[@"legacy"];
    NSDictionary *userResult = result[@"core"][@"user_results"][@"result"];
    NSDictionary *userCore   = userResult[@"core"];
    // GraphQL nests the avatar URL under "avatar.image_url" rather than
    // the v1.1 "profile_image_url_https". The URL format (including _normal
    // suffix) is identical, so no further rewriting is needed.
    NSString *avatarURL = userResult[@"avatar"][@"image_url"] ?: @"";

    NSDictionary *user = @{
        @"name":                    userCore[@"name"]        ?: @"",
        @"screen_name":             userCore[@"screen_name"] ?: @"",
        @"profile_image_url_https": avatarURL,
        // GraphQL uses is_blue_verified (BOOL); v1.1 used verified (BOOL).
        @"verified":                userResult[@"is_blue_verified"] ?: @NO,
    };

    return @{
        @"full_text": legacy[@"full_text"] ?: @"",
        @"user":      user,
        @"entities":  legacy[@"entities"]  ?: @{},
    };
}

// ─── ApolloTweetProtocol ──────────────────────────────────────────────────────

@interface ApolloTweetProtocol : NSURLProtocol
@end

@implementation ApolloTweetProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // Only intercept apollogur tweet requests that we haven't already handled.
    if (![request.URL.absoluteString hasPrefix:kApolloTweetBaseURL]) return NO;
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request])  return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *tweetId                  = self.request.URL.lastPathComponent;
    id<NSURLProtocolClient> client     = self.client;
    NSURLRequest           *origRequest = self.request;

    ApolloLog(@"TweetBuddy: intercepted request for tweet %@", tweetId);

    [ApolloTweetProtocol resolveGuestToken:^(NSString *token, NSError *tokenError) {
        if (!token) {
            ApolloLog(@"TweetBuddy: guest token fetch failed: %@", tokenError.localizedDescription);
            [client URLProtocol:self didFailWithError:tokenError
                ?: [NSError errorWithDomain:@"ApolloTweetProtocol" code:-1
                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to obtain guest token"}]];
            return;
        }

        [ApolloTweetProtocol fetchTweet:tweetId
                             guestToken:token
                             completion:^(NSDictionary *v1dict, NSError *fetchError) {
            if (!v1dict) {
                ApolloLog(@"TweetBuddy: GraphQL fetch failed: %@", fetchError.localizedDescription);
                [client URLProtocol:self didFailWithError:fetchError];
                return;
            }

            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:v1dict options:0 error:nil];
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                initWithURL:origRequest.URL
                statusCode:200
                HTTPVersion:@"HTTP/1.1"
                headerFields:@{@"Content-Type": @"application/json"}];

            [client URLProtocol:self didReceiveResponse:response
                cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [client URLProtocol:self didLoadData:jsonData];
            [client URLProtocolDidFinishLoading:self];
            ApolloLog(@"TweetBuddy: delivered synthetic v1.1 response for tweet %@", tweetId);
        }];
    }];
}

- (void)stopLoading {}

// ─── Guest Token ──────────────────────────────────────────────────────────────

// Resolves a cached guest token or scrapes a fresh one from x.com.
// The completion block is called on an arbitrary background queue.
+ (void)resolveGuestToken:(void (^)(NSString *token, NSError *error))completion {
    dispatch_async(sTokenQueue, ^{
        // Return cached token if still valid.
        if (sGuestToken && sTokenFetchDate &&
            [[NSDate date] timeIntervalSinceDate:sTokenFetchDate] < kGuestTokenMaxAge) {
            ApolloLog(@"TweetBuddy: using cached guest token");
            completion(sGuestToken, nil);
            return;
        }

        // Fetch a fresh token from x.com homepage. The guest token is set via
        // inline JS as `gt=<digits>;` — it does NOT appear in response headers.
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kXHomepageURL]];
        [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:req];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err || !data) {
                completion(nil, err);
                return;
            }
            NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"gt=([0-9]+);" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:html
                options:0 range:NSMakeRange(0, html.length)];
            if (!match || match.numberOfRanges < 2) {
                completion(nil, [NSError errorWithDomain:@"ApolloTweetProtocol" code:-2 userInfo:@{
                    NSLocalizedDescriptionKey: @"Could not find gt= in x.com HTML"
                }]);
                return;
            }
            NSString *token = [html substringWithRange:[match rangeAtIndex:1]];
            ApolloLog(@"TweetBuddy: fetched fresh guest token");
            // Update cache (we're already on sTokenQueue).
            dispatch_async(sTokenQueue, ^{
                sGuestToken     = token;
                sTokenFetchDate = [NSDate date];
            });
            completion(token, nil);
        }] resume];
    });
}

// ─── GraphQL Fetch ────────────────────────────────────────────────────────────

// Calls X's internal TweetResultByRestId endpoint and transforms the response.
// The completion block is called on an arbitrary background queue.
+ (void)fetchTweet:(NSString *)tweetId
        guestToken:(NSString *)guestToken
        completion:(void (^)(NSDictionary *v1dict, NSError *error))completion {

    // Build query string. Variables and features match the working proof-of-concept.
    NSString *variables = [NSString stringWithFormat:
        @"{\"tweetId\":\"%@\",\"withCommunity\":false,"
         "\"includePromotedContent\":false,\"withVoice\":false}", tweetId];
    NSString *features =
        @"{\"creator_subscriptions_tweet_preview_api_enabled\":true,"
         "\"view_counts_everywhere_api_enabled\":true}";

    NSURLComponents *components = [NSURLComponents componentsWithString:kXGraphQLURL];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"variables" value:variables],
        [NSURLQueryItem queryItemWithName:@"features"  value:features],
    ];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:components.URL];
    [req setValue:kXBearerToken      forHTTPHeaderField:@"authorization"];
    [req setValue:guestToken         forHTTPHeaderField:@"x-guest-token"];
    [req setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    [req setValue:@"https://x.com"   forHTTPHeaderField:@"Origin"];
    [req setValue:@"https://x.com/"  forHTTPHeaderField:@"Referer"];
    // Prevent re-interception by our own protocol.
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:req];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            completion(nil, err);
            return;
        }

        // If the token was rejected, invalidate cache so the next call re-fetches.
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
        if (httpResp.statusCode == 401 || httpResp.statusCode == 403) {
            dispatch_async(sTokenQueue, ^{ sGuestToken = nil; sTokenFetchDate = nil; });
            completion(nil, [NSError errorWithDomain:@"ApolloTweetProtocol" code:httpResp.statusCode
                userInfo:@{NSLocalizedDescriptionKey: @"Guest token rejected; will refresh on retry"}]);
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSDictionary *result = json[@"data"][@"tweetResult"][@"result"];
        if (!result) {
            completion(nil, jsonError ?: [NSError errorWithDomain:@"ApolloTweetProtocol" code:-3
                userInfo:@{NSLocalizedDescriptionKey: @"Unexpected GraphQL response structure"}]);
            return;
        }

        completion(ATBTransformResult(result), nil);
    }] resume];
}

@end

// ─── Session Configuration Hook ───────────────────────────────────────────────
//
// TweetBuddy creates its NSURLSession with [NSURLSessionConfiguration
// defaultSessionConfiguration]. NSURLProtocol.registerClass: only covers the
// shared session; to intercept a custom session's traffic we must inject the
// protocol into the configuration's protocolClasses before the session is built.

%hook NSURLSessionConfiguration

+ (instancetype)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;
    NSMutableArray *protocols = [NSMutableArray arrayWithArray:config.protocolClasses ?: @[]];
    if (![protocols containsObject:[ApolloTweetProtocol class]]) {
        [protocols insertObject:[ApolloTweetProtocol class] atIndex:0];
        config.protocolClasses = protocols;
    }
    return config;
}

%end

// ─── Constructor ──────────────────────────────────────────────────────────────

%ctor {
    sTokenQueue = dispatch_queue_create("com.apollo.tweetbuddy.tokenqueue", DISPATCH_QUEUE_SERIAL);
    ApolloLog(@"TweetBuddy: ApolloTweetProtocol registered");
}
