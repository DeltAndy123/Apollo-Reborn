#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloSwiftAllocCapture.h"

// MARK: - Subreddit Weather

static __unsafe_unretained id sWeatherManager = nil;
static Ivar sWeatherFetchingPossibleIvar = NULL;

static ptrdiff_t ApolloWeatherFetchingPossibleOffset(id manager) {
    if (!manager) return 0x10;

    if (!sWeatherFetchingPossibleIvar) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList([manager class], &ivarCount);
        if (ivars) {
            for (unsigned int i = 0; i < ivarCount; i++) {
                const char *name = ivar_getName(ivars[i]);
                if (name && strstr(name, "isWeatherFetchingPossible")) {
                    sWeatherFetchingPossibleIvar = ivars[i];
                    break;
                }
            }
            free(ivars);
        }
    }

    return sWeatherFetchingPossibleIvar ? ivar_getOffset(sWeatherFetchingPossibleIvar) : 0x10;
}

static void ApolloForceSubredditWeatherEnabled(id manager) {
    if (!manager) return;

    ptrdiff_t offset = ApolloWeatherFetchingPossibleOffset(manager);
    uint8_t *bytes = (uint8_t *)(__bridge void *)manager;
    bytes[offset] = 1;
    ApolloLog(@"[Weather] Forced WeatherManager.isWeatherFetchingPossible=YES at offset 0x%tx", offset);
}

static void ApolloScheduleWeatherEnable(id manager) {
    if (!manager) return;

    // WeatherManager.init sets this flag to false before kicking off the dead
    // apollogur gate request. Re-apply after init has finished.
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloForceSubredditWeatherEnabled(manager);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloForceSubredditWeatherEnabled(manager);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloForceSubredditWeatherEnabled(manager);
    });
}

static void ApolloWeatherManagerCaptured(id object, void *context) {
    sWeatherManager = object;
    ApolloScheduleWeatherEnable(sWeatherManager);
}

%ctor {
    ApolloRegisterSwiftAllocCapture(objc_getClass("_TtC6Apollo14WeatherManager"), ApolloWeatherManagerCaptured, NULL);
}
