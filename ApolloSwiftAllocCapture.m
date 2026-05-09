#import "ApolloSwiftAllocCapture.h"

#import "fishhook.h"

@interface ApolloSwiftAllocCaptureEntry : NSObject
@property (nonatomic, assign) void *metadata;
@property (nonatomic, assign) ApolloSwiftAllocCaptureCallback callback;
@property (nonatomic, assign) void *context;
@property (nonatomic, assign) BOOL captured;
@end

@implementation ApolloSwiftAllocCaptureEntry
@end

static NSMutableArray<ApolloSwiftAllocCaptureEntry *> *sApolloSwiftAllocCaptureEntries;
static void *(*sOrigSwiftAllocObject)(void *type, size_t size, size_t alignMask);
static BOOL sApolloSwiftAllocHookInstalled = NO;

static BOOL ApolloSwiftAllocAllEntriesCaptured(void) {
    for (ApolloSwiftAllocCaptureEntry *entry in sApolloSwiftAllocCaptureEntries) {
        if (!entry.captured) return NO;
    }
    return YES;
}

static void ApolloSwiftAllocMaybeUnhook(void) {
    if (sApolloSwiftAllocHookInstalled && sOrigSwiftAllocObject && ApolloSwiftAllocAllEntriesCaptured()) {
        rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)sOrigSwiftAllocObject, NULL}}, 1);
        sApolloSwiftAllocHookInstalled = NO;
    }
}

static void *ApolloHookedSwiftAllocObject(void *type, size_t size, size_t alignMask) {
    void *object = sOrigSwiftAllocObject(type, size, alignMask);

    ApolloSwiftAllocCaptureCallback callback = NULL;
    void *context = NULL;
    @synchronized(sApolloSwiftAllocCaptureEntries) {
        for (ApolloSwiftAllocCaptureEntry *entry in sApolloSwiftAllocCaptureEntries) {
            if (!entry.captured && entry.metadata == type) {
                entry.captured = YES;
                callback = entry.callback;
                context = entry.context;
                break;
            }
        }
    }

    if (callback) {
        callback((__bridge id)object, context);
    }

    @synchronized(sApolloSwiftAllocCaptureEntries) {
        ApolloSwiftAllocMaybeUnhook();
    }

    return object;
}

void ApolloRegisterSwiftAllocCapture(Class swiftClass, ApolloSwiftAllocCaptureCallback callback, void *context) {
    if (!swiftClass || !callback) return;

    @synchronized([ApolloSwiftAllocCaptureEntry class]) {
        if (!sApolloSwiftAllocCaptureEntries) {
            sApolloSwiftAllocCaptureEntries = [NSMutableArray array];
        }

        ApolloSwiftAllocCaptureEntry *entry = [ApolloSwiftAllocCaptureEntry new];
        entry.metadata = (__bridge void *)swiftClass;
        entry.callback = callback;
        entry.context = context;
        [sApolloSwiftAllocCaptureEntries addObject:entry];

        if (!sApolloSwiftAllocHookInstalled) {
            rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)ApolloHookedSwiftAllocObject, (void **)&sOrigSwiftAllocObject}}, 1);
            sApolloSwiftAllocHookInstalled = YES;
        }
    }
}
