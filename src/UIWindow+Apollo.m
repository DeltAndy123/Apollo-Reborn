#import "UIWindow+Apollo.h"
#import "ApolloCommon.h"

// https://stackoverflow.com/a/21848247
@implementation UIWindow (Apollo)
- (UIViewController *)visibleViewController {
    UIViewController *rootViewController = self.rootViewController;
    return [UIWindow getVisibleViewControllerFrom:rootViewController];
}

+ (UIViewController *) getVisibleViewControllerFrom:(UIViewController *) vc {
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return [UIWindow getVisibleViewControllerFrom:[((UINavigationController *) vc) visibleViewController]];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        return [UIWindow getVisibleViewControllerFrom:[((UITabBarController *) vc) selectedViewController]];
    } else if ([vc isKindOfClass:[UISplitViewController class]]) {
        // On iPad with the two-pane layout, a tab's view controller is a
        // UISplitViewController wrapping the feed/detail nav controllers.
        UIViewController *active = ApolloActiveColumnViewController(vc);
        if (active && active != vc) return [UIWindow getVisibleViewControllerFrom:active];
        return vc;
    } else {
        if (vc.presentedViewController) {
            return [UIWindow getVisibleViewControllerFrom:vc.presentedViewController];
        } else {
            return vc;
        }
    }
}
@end
