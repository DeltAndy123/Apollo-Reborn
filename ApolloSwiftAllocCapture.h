#import <Foundation/Foundation.h>

typedef void (*ApolloSwiftAllocCaptureCallback)(id object, void *context);

__BEGIN_DECLS
void ApolloRegisterSwiftAllocCapture(Class swiftClass, ApolloSwiftAllocCaptureCallback callback, void *context);
__END_DECLS
