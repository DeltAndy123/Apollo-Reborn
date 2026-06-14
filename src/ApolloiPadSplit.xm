#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

// MARK: - iPad Two-Pane Layout
//
// Apollo was designed phone-only: on iPad it's the same single-column layout
// just stretched to fill the width. This feature wraps each browsing tab's
// ApolloNavigationController (the feed) in a UISplitViewController, with a
// second ApolloNavigationController as the detail pane on the right showing
// the tapped post's comments.
//
// Architecture:
// - Primary column = the existing per-tab ApolloNavigationController (feed,
//   subreddit/home/profile listings, or Settings root). Untouched otherwise.
// - Secondary column = a fresh ApolloNavigationController whose root is a
//   placeholder VC ("Select a post to read" / "Select a setting"), reusing
//   ApolloNavigationController so the detail pane gets Apollo's
//   theming/transitions for free.
// - The only navigation choke point in Apollo is
//   -[ApolloNavigationController pushViewController:animated:] (every "open
//   post" / "open settings page" call funnels through it). We hook it and
//   route by destination based on a per-split policy:
//
//   Browsing policy (the default; "right" = a single post's comment thread or
//   a single inbox conversation, i.e. CommentsViewController/
//   CommentPreviewViewController/PrivateMessageViewController):
//     - primary pushes a "right" VC          -> replace secondary stack, show it
//     - primary pushes a non-"right" VC      -> %orig (stays in left pane)
//     - secondary pushes a "right" VC        -> %orig (stacks in right pane,
//                                                e.g. tapping another post from
//                                                inside comments)
//     - secondary pushes a non-"right" VC    -> redirect to primary's push
//                                                (e.g. tapping a subreddit/user
//                                                from inside comments opens it
//                                                in the left pane)
//
//   Settings policy (tagged on the Settings tab's split at wrap time):
//     - primary pushes anything   -> replace secondary stack, show it
//     - secondary pushes anything -> %orig (drill-downs stack on the right,
//                                    master-detail style)
//
// - Collapse/expand (rotation, Slide Over, narrow multitasking) is handled by
//   a UISplitViewControllerDelegate: on collapse, the secondary pane's stack
//   (if not just the placeholder) is appended onto the primary stack so the
//   open page survives; on expand, the trailing pushed-to-detail view
//   controllers are moved back into the secondary pane.
//
// Gated on iPad idiom + Liquid Glass build + the "Two-Pane Layout" setting
// (CustomAPIViewController, General section). The split-view layout only
// behaves correctly when Apollo's executable is linked against the iOS 26 SDK
// (IsLiquidGlass(), ApolloCommon.m) -- on the original SDK 16.2 binary,
// UISplitViewControllerStyleDoubleColumn collapses to a single column on the
// iOS 26/27 simulator/runtime regardless of width, making the wrap a no-op
// that looks identical to the stretched single-column layout. iPhone is
// completely untouched: self.splitViewController is nil for phone nav
// controllers, so the push hook is a no-op there.

// MARK: - Right-pane target classes
//
// View controllers that represent "opened a single post's comment thread" or
// "opened a single conversation" and should be routed to the secondary
// (right/detail) pane. Comment *lists* (a user's comments, a subreddit's
// comments, saved-post comments) and the inbox's conversation *list* are
// feed-like browsing surfaces and belong in the left pane.
static NSArray<Class> *ApolloIPadRightTargetClasses(void) {
    static NSArray<Class> *classes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<Class> *found = [NSMutableArray array];
        for (NSString *name in @[
            @"_TtC6Apollo22CommentsViewController",
            @"_TtC6Apollo28CommentPreviewViewController",
            // Private-message / modmail conversation thread, pushed from the
            // Inbox tab's conversation list.
            @"_TtC6Apollo28PrivateMessageViewController",
        ]) {
            Class cls = objc_getClass(name.UTF8String);
            if (cls) [found addObject:cls];
        }
        classes = [found copy];
    });
    return classes;
}

static BOOL ApolloIsIPadRightTargetViewController(UIViewController *vc) {
    if (!vc) return NO;
    for (Class cls in ApolloIPadRightTargetClasses()) {
        if ([vc isKindOfClass:cls]) return YES;
    }
    return NO;
}

// MARK: - Per-split routing policy

typedef NS_ENUM(NSInteger, ApolloIPadSplitPolicy) {
    // Right pane shows a single post's comments; everything else routes left.
    ApolloIPadSplitPolicyBrowsing = 0,
    // Right pane mirrors whatever is pushed from the Settings root, and
    // drill-downs from a settings page stack on the right (master-detail).
    ApolloIPadSplitPolicySettings = 1,
};

static char kApolloSplitPolicyKey;

static ApolloIPadSplitPolicy ApolloSplitPolicyForSplit(UISplitViewController *split) {
    NSNumber *policy = objc_getAssociatedObject(split, &kApolloSplitPolicyKey);
    return policy ? (ApolloIPadSplitPolicy)policy.integerValue : ApolloIPadSplitPolicyBrowsing;
}

// MARK: - Layout kick
//
// Apollo's content view controllers were designed phone-only and some size
// themselves against UIScreen.main.bounds rather than their own view's bounds
// on first layout (e.g. text post bodies render shifted into the right pane
// until the next rotation forces a relayout). Mimic what a rotation triggers
// -- a viewWillTransitionToSize: call plus a forced layout pass -- immediately
// after a view controller is placed into a column, so it renders correctly at
// its real column width on first appearance.

// AsyncDisplayKit's ASTableView/ASCollectionView (UITableView/UICollectionView
// subclasses) override -reloadData to re-measure every ASCellNode through
// ASDK's data controller against the view's *current* bounds. Cells realized
// while the comments table view still had its pre-split (full window) width
// keep that stale, too-wide measurement and render shifted/overflowing to the
// right; cells created later -- e.g. by scrolling -- are measured fresh
// against the now-correct column width and render fine. By the time this
// runs, the outer viewWillTransitionToSize:/layoutIfNeeded pass has already
// settled the table view's bounds to the real column width, so -reloadData
// re-measures the already-realized cells against the correct width too.
static void ApolloIPadReloadAsyncTables(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) {
        ApolloLog(@"[iPadSplit]   reloadData on %@ bounds=%@", NSStringFromClass([view class]), NSStringFromCGRect(view.bounds));
        [(UITableView *)view reloadData];
    } else if ([view isKindOfClass:[UICollectionView class]]) {
        ApolloLog(@"[iPadSplit]   reloadData on %@ bounds=%@", NSStringFromClass([view class]), NSStringFromCGRect(view.bounds));
        [(UICollectionView *)view reloadData];
    }
    for (UIView *subview in view.subviews) {
        ApolloIPadReloadAsyncTables(subview);
    }
}

// A single kick fires one runloop tick after the view controller is placed
// into its column. In the two-pane layout, the secondary (detail) column's
// content view controller is given a view as wide as the *entire* split
// (overlapping the primary column), clipped down to the narrower remaining
// space by an ancestor view. ASDK's ASTableNode measures cells against that
// full, unclipped bounds width, so comment/post text wraps too wide and the
// portion past the clipped edge is cut off. Shrink the view to the actually-
// visible width -- the split's width minus the primary column's width --
// before the transition/reload pass below so cells measure correctly.
static void ApolloIPadKickLayoutPass(UIViewController *vc, int remainingRetries) {
    if (!vc) return;
    UIView *view = vc.view; // force the view to load
    UISplitViewController *split = vc.splitViewController;
    if (split && split.displayMode == UISplitViewControllerDisplayModeOneBesideSecondary) {
        CGFloat splitWidth = split.view.bounds.size.width;
        UINavigationController *primaryNav = (UINavigationController *)[split viewControllerForColumn:UISplitViewControllerColumnPrimary];
        CGFloat primaryWidth = primaryNav.view.bounds.size.width;
        CGFloat visibleWidth = splitWidth - primaryWidth;
        if (visibleWidth > 0 && visibleWidth < view.bounds.size.width && fabs(view.bounds.size.width - splitWidth) < 0.5) {
            // The unclipped view spans the full split width starting at x=0,
            // and the *visible* (non-overlapped) portion is its right edge --
            // the rightmost `visibleWidth` points. Setting bounds.size.width
            // also shrinks frame.size.width, which UIKit re-centers around the
            // view's unchanged `center`, sliding frame.origin.x right by HALF
            // the size delta (from 0 to primaryWidth/2). To land the view's
            // left edge at x=primaryWidth (the start of the visible column),
            // it needs to move right by the other half of the delta too.
            CGRect bounds = view.bounds;
            bounds.size.width = visibleWidth;
            view.bounds = bounds;

            CGRect frame = view.frame;
            frame.origin.x += primaryWidth / 2.0;
            view.frame = frame;
        }
    }
    CGSize size = view.bounds.size;
    ApolloLog(@"[iPadSplit] Kick pass %d for %@ view.bounds=%@", remainingRetries, NSStringFromClass([vc class]), NSStringFromCGRect(view.bounds));
    if (size.width > 0 && size.height > 0) {
        // -viewWillTransitionToSize:withTransitionCoordinator: is declared
        // non-null; route the "no coordinator" value through a local so
        // -Wnonnull doesn't flag the literal nil we actually want to pass.
        id<UIViewControllerTransitionCoordinator> noCoordinator = nil;
        [vc viewWillTransitionToSize:size withTransitionCoordinator:noCoordinator];
    }
    [view setNeedsLayout];
    [view layoutIfNeeded];
    ApolloIPadReloadAsyncTables(view);

    if (remainingRetries > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloIPadKickLayoutPass(vc, remainingRetries - 1);
        });
    }
}

static void ApolloIPadKickLayout(UIViewController *vc) {
    ApolloIPadKickLayoutPass(vc, 5);
}

// MARK: - Detail VC opaque-bar extension (Pure Black letterboxing fix)
//
// Pure Black Dark Mode makes Apollo's nav/tool bars opaque. By default
// (extendedLayoutIncludesOpaqueBars == NO) UIKit then *insets* a VC's view to
// avoid the opaque bars, shrinking the detail column's content view (measured
// ~566pt tall vs the full ~834pt it gets under translucent bars). The shorter
// view makes inline image cells aspect-fit smaller (side gaps) and leaves the
// scene/window backdrop exposed below (black full screen / gray Stage-Manager
// windowed -- matching native apps like Files). Tell the VC to extend under
// opaque bars too, matching the translucent (Pure Black off) behavior where
// the view fills the whole column.
//
// Must be set before the view's first layout pass (i.e. from -viewDidLoad),
// not reactively from ApolloIPadKickLayoutPass after vc.view has already been
// accessed/laid-out once -- setting it that late is non-deterministic.
static void ApolloIPadExtendUnderOpaqueBars(UIViewController *vc) {
    if (!vc) return;
    vc.edgesForExtendedLayout = UIRectEdgeAll;
    vc.extendedLayoutIncludesOpaqueBars = YES;
}

// MARK: - Placeholder detail pane

@interface ApolloIPadPlaceholderDetailViewController : UIViewController
@property (nonatomic, copy) NSString *placeholderText;
@end

@implementation ApolloIPadPlaceholderDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *label = [[UILabel alloc] init];
    label.text = self.placeholderText ?: @"Select a post to read";
    label.textColor = [UIColor secondaryLabelColor];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

@end

BOOL ApolloIsIPadSplitPlaceholderViewController(UIViewController *vc) {
    return [vc isKindOfClass:[ApolloIPadPlaceholderDetailViewController class]];
}

// MARK: - Detail-pane separation (collapse/expand adaptivity, shared)
//
// Inverse of the merge in -topColumnForCollapsingToProposedTopColumn: below:
// if primaryNav's stack has a "right target" VC (and everything pushed after
// it), peel that run off into detailNav so the open post returns to the
// detail (right) pane instead of staying as the top of the now-expanded
// primary (left) pane.
static void ApolloIPadSeparateDetailFromPrimary(UISplitViewController *split) {
    UINavigationController *primaryNav = (UINavigationController *)[split viewControllerForColumn:UISplitViewControllerColumnPrimary];
    UINavigationController *detailNav = (UINavigationController *)[split viewControllerForColumn:UISplitViewControllerColumnSecondary];
    NSArray<UIViewController *> *vcs = primaryNav.viewControllers;
    ApolloIPadSplitPolicy policy = ApolloSplitPolicyForSplit(split);

    NSUInteger splitIndex = NSNotFound;
    if (policy == ApolloIPadSplitPolicySettings) {
        // Everything after the Settings root was pushed-to-detail.
        splitIndex = (vcs.count > 1) ? 1 : NSNotFound;
    } else {
        for (NSUInteger i = 0; i < vcs.count; i++) {
            if (ApolloIsIPadRightTargetViewController(vcs[i])) {
                splitIndex = i;
                break;
            }
        }
    }
    if (splitIndex == NSNotFound || splitIndex == 0) return;

    NSArray<UIViewController *> *primaryPart = [vcs subarrayWithRange:NSMakeRange(0, splitIndex)];
    NSArray<UIViewController *> *detailPart = [vcs subarrayWithRange:NSMakeRange(splitIndex, vcs.count - splitIndex)];
    [primaryNav setViewControllers:primaryPart animated:NO];
    [detailNav setViewControllers:detailPart animated:NO];
    ApolloLog(@"[iPadSplit] Expanded: moved %lu detail VC(s) back to secondary pane", (unsigned long)detailPart.count);

    UIViewController *lastDetail = detailPart.lastObject;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloIPadKickLayout(lastDetail);
    });
}

// MARK: - Split view delegate (collapse/expand adaptivity)

@interface ApolloIPadSplitDelegate : NSObject <UISplitViewControllerDelegate>
@end

@implementation ApolloIPadSplitDelegate

// Regular -> compact (rotation to portrait on smaller iPads, Slide Over,
// narrow multitasking). If the detail pane is showing real content (not just
// the placeholder), fold it onto the end of the primary stack so it remains
// reachable/visible after collapsing to one column.
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController *)svc
    topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    UINavigationController *primaryNav = (UINavigationController *)[svc viewControllerForColumn:UISplitViewControllerColumnPrimary];
    UINavigationController *detailNav = (UINavigationController *)[svc viewControllerForColumn:UISplitViewControllerColumnSecondary];
    NSArray<UIViewController *> *detailStack = detailNav.viewControllers;

    if (detailStack.count > 0 && ![detailStack.firstObject isKindOfClass:[ApolloIPadPlaceholderDetailViewController class]]) {
        NSArray<UIViewController *> *primaryStack = primaryNav.viewControllers;
        if (![primaryStack.lastObject isEqual:detailStack.lastObject]) {
            NSArray<UIViewController *> *merged = [primaryStack arrayByAddingObjectsFromArray:detailStack];
            [primaryNav setViewControllers:merged animated:NO];

            // detailNav must not keep referencing the VCs we just moved onto
            // primaryNav -- a view controller listed in two navigation
            // controllers' viewControllers shares one UINavigationItem, and
            // when both navigation bars later run layoutSubviews, UIKit finds
            // the item's navigationBar no longer matches `self` and asserts
            // ("Layout requested for visible navigation bar ... when the top
            // item belongs to a different navigation bar"), crashing on
            // collapse or a later expand. Reset detail to a fresh placeholder
            // so ownership stays single throughout.
            ApolloIPadPlaceholderDetailViewController *placeholder = [ApolloIPadPlaceholderDetailViewController new];
            if (ApolloSplitPolicyForSplit(svc) == ApolloIPadSplitPolicySettings) {
                placeholder.placeholderText = @"Select a setting";
            }
            [detailNav setViewControllers:@[placeholder] animated:NO];

            ApolloLog(@"[iPadSplit] Collapsed: merged %lu detail VC(s) onto primary stack", (unsigned long)detailStack.count);
        }
    }
    return UISplitViewControllerColumnPrimary;
}

// Compact -> regular (rotation back to landscape, leaving Slide Over, wider
// multitasking). If the (now single) stack has content that was previously
// pushed to the right, peel it (and anything pushed after it) back off into
// the secondary pane.
//
// In practice this legacy delegate method is not invoked for
// UISplitViewControllerStyleDoubleColumn -- ApolloIPadSplitViewController's
// -viewWillTransitionToSize:withTransitionCoordinator: override below is the
// mechanism that actually runs ApolloIPadSeparateDetailFromPrimary on
// collapse->regular. This is kept (and still correct, sharing the same
// helper) in case a future OS does call it.
- (UIViewController *)splitViewController:(UISplitViewController *)svc
    separateSecondaryFromPrimaryViewController:(UIViewController *)primaryViewController {
    ApolloIPadSeparateDetailFromPrimary(svc);
    return [svc viewControllerForColumn:UISplitViewControllerColumnSecondary];
}

@end

static ApolloIPadSplitDelegate *ApolloIPadSplitDelegateShared(void) {
    static ApolloIPadSplitDelegate *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [ApolloIPadSplitDelegate new];
    });
    return shared;
}

// MARK: - Split subclass (initial-layout + rotation fixes)

@interface ApolloIPadSplitViewController : UISplitViewController
@end

@implementation ApolloIPadSplitViewController

// Force a real layout pass once we're on screen so columns -- and the
// placeholder's centered label -- size against their actual column bounds
// instead of whatever (often full-screen) frame they were first loaded with.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    for (NSNumber *columnNumber in @[
        @(UISplitViewControllerColumnPrimary),
        @(UISplitViewControllerColumnSecondary),
    ]) {
        UISplitViewControllerColumn column = (UISplitViewControllerColumn)columnNumber.integerValue;
        UIViewController *columnVC = [self viewControllerForColumn:column];
        if ([columnVC isKindOfClass:[UINavigationController class]]) {
            ApolloIPadKickLayout(((UINavigationController *)columnVC).topViewController);
        }
    }
}

// Collapse->regular transitions (e.g. Stage Manager window resize back to
// split width) don't invoke
// -[ApolloIPadSplitDelegate splitViewController:separateSecondaryFromPrimaryViewController:]
// for UISplitViewControllerStyleDoubleColumn -- the column assignments never
// change, only primaryNav's viewControllers array (mutated by the collapse
// merge), so UIKit just re-shows the existing primary/secondary columns as
// regular without asking. Catch it here instead: once the transition
// completes and we're no longer collapsed, peel any merged-on detail VC back
// off of primaryNav.
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak ApolloIPadSplitViewController *weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        ApolloIPadSplitViewController *strongSelf = weakSelf;
        if (strongSelf && !strongSelf.isCollapsed) {
            ApolloIPadSeparateDetailFromPrimary(strongSelf);
        }
    }];
}

// Always allow free rotation on iPad regardless of what a transitioning child
// (e.g. a fullscreen image viewer mid-dismiss) reports, so the revealed split
// doesn't briefly snap to portrait before "teleporting" back to landscape.
- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end

// MARK: - Split construction

static UISplitViewController *ApolloMakeSplitForPrimaryNav(UINavigationController *primaryNav, ApolloIPadSplitPolicy policy) {
    Class navClass = [primaryNav class];

    ApolloIPadPlaceholderDetailViewController *placeholder = [ApolloIPadPlaceholderDetailViewController new];
    if (policy == ApolloIPadSplitPolicySettings) {
        placeholder.placeholderText = @"Select a setting";
    }
    UINavigationController *detailNav = [[navClass alloc] initWithRootViewController:placeholder];

    ApolloIPadSplitViewController *split = [[ApolloIPadSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    // Pure Black makes the hosting tab bar opaque, which (without this) insets
    // the split's own view by the tab bar's height -- shrinking both columns
    // equally (observed ~770pt vs the full ~834pt scene height) and exposing a
    // band of the window's background color below the split. Set this at
    // construction time, before the split's view is ever loaded, so it's
    // honored on the very first layout (see ApolloIPadExtendUnderOpaqueBars).
    ApolloIPadExtendUnderOpaqueBars((UIViewController *)split);
    split.delegate = ApolloIPadSplitDelegateShared();
    split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    [split setViewController:primaryNav forColumn:UISplitViewControllerColumnPrimary];
    [split setViewController:detailNav forColumn:UISplitViewControllerColumnSecondary];
    [split setViewController:primaryNav forColumn:UISplitViewControllerColumnCompact];
    objc_setAssociatedObject(split, &kApolloSplitPolicyKey, @(policy), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return split;
}

// MARK: - Hooks

static char kApolloTabsWrappedKey;

%hook _TtC6Apollo22ApolloTabBarController

// viewControllers aren't set yet at viewDidLoad (the scene delegate assigns
// them after the tab bar controller's view loads), so wrap on the first
// viewWillAppear: instead. Guarded by the associated-object flag below so
// later reappearances (e.g. dismissing a modal) are no-ops.
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!ApolloIsIPad() || !sIPadTwoPaneLayout || !IsLiquidGlass()) return;
    if (objc_getAssociatedObject(self, &kApolloTabsWrappedKey)) return;
    objc_setAssociatedObject(self, &kApolloTabsWrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITabBarController *tabBarController = (UITabBarController *)self;
    NSArray<UIViewController *> *tabs = tabBarController.viewControllers;
    if (tabs.count == 0) return;

    Class navClass = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (!navClass) return;
    Class settingsClass = objc_getClass("_TtC6Apollo22SettingsViewController");

    NSMutableArray<UIViewController *> *wrapped = [NSMutableArray arrayWithCapacity:tabs.count];
    for (UIViewController *tab in tabs) {
        if ([tab isKindOfClass:navClass]) {
            UINavigationController *tabNav = (UINavigationController *)tab;
            ApolloIPadSplitPolicy policy = ApolloIPadSplitPolicyBrowsing;
            UIViewController *root = tabNav.viewControllers.firstObject;
            if (settingsClass && [root isKindOfClass:settingsClass]) {
                policy = ApolloIPadSplitPolicySettings;
            }
            UISplitViewController *split = ApolloMakeSplitForPrimaryNav(tabNav, policy);
            split.tabBarItem = tab.tabBarItem;
            [wrapped addObject:split];
        } else {
            [wrapped addObject:tab];
        }
    }
    tabBarController.viewControllers = wrapped;
    ApolloLog(@"[iPadSplit] Wrapped %lu/%lu tab(s) in UISplitViewController", (unsigned long)wrapped.count, (unsigned long)tabs.count);
}

%end

%hook _TtC6Apollo26ApolloNavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UINavigationController *selfNav = (UINavigationController *)self;
    UISplitViewController *split = selfNav.splitViewController;
    if (!split || split.isCollapsed) {
        %orig;
        return;
    }

    UINavigationController *primaryNav = (UINavigationController *)[split viewControllerForColumn:UISplitViewControllerColumnPrimary];
    UINavigationController *detailNav = (UINavigationController *)[split viewControllerForColumn:UISplitViewControllerColumnSecondary];
    ApolloIPadSplitPolicy policy = ApolloSplitPolicyForSplit(split);

    if (selfNav == primaryNav) {
        BOOL routeToDetail = (policy == ApolloIPadSplitPolicySettings) || ApolloIsIPadRightTargetViewController(viewController);
        if (routeToDetail && detailNav) {
            [detailNav setViewControllers:@[viewController] animated:NO];
            if (split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly) {
                [split showColumn:UISplitViewControllerColumnSecondary];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloIPadKickLayout(viewController);
            });
            ApolloLog(@"[iPadSplit] Routed push of %@ to detail pane", NSStringFromClass([viewController class]));
            return;
        }
        %orig;
        return;
    }

    if (selfNav == detailNav) {
        BOOL stacksInDetail = (policy == ApolloIPadSplitPolicySettings) || ApolloIsIPadRightTargetViewController(viewController);
        if (!stacksInDetail && primaryNav) {
            [primaryNav pushViewController:viewController animated:animated];
            if (split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly) {
                // The left pane is hidden (comments shown full-width). Without
                // this, the redirected push lands on the primary stack
                // invisibly and the tap appears to do nothing.
                [split showColumn:UISplitViewControllerColumnPrimary];
            }
            ApolloLog(@"[iPadSplit] Routed push of %@ from detail pane to primary pane", NSStringFromClass([viewController class]));
            return;
        }
        %orig;
        return;
    }

    %orig;
}

%end

// MARK: - Detail VC hooks (Pure Black opaque-bar extension)
//
// Apply ApolloIPadExtendUnderOpaqueBars to each "right target" VC class (the
// same set ApolloIsIPadRightTargetViewController() routes into the detail
// column, see ApolloIPadRightTargetClasses() above) at -viewDidLoad, before
// their view's first layout pass. Gated on the same feature flags used to
// wrap the tabs in split view controllers in the first place, so this is a
// no-op everywhere except the iPad two-pane Liquid Glass layout.

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLoad {
    %orig;
    if (ApolloIsIPad() && sIPadTwoPaneLayout && IsLiquidGlass()) {
        ApolloIPadExtendUnderOpaqueBars((UIViewController *)self);
    }
}

%end

%hook _TtC6Apollo28CommentPreviewViewController

- (void)viewDidLoad {
    %orig;
    if (ApolloIsIPad() && sIPadTwoPaneLayout && IsLiquidGlass()) {
        ApolloIPadExtendUnderOpaqueBars((UIViewController *)self);
    }
}

%end

%hook _TtC6Apollo28PrivateMessageViewController

- (void)viewDidLoad {
    %orig;
    if (ApolloIsIPad() && sIPadTwoPaneLayout && IsLiquidGlass()) {
        ApolloIPadExtendUnderOpaqueBars((UIViewController *)self);
    }
}

%end

// MARK: - Message input bar width (detail pane)
//
// MessagesViewController's compose bar is hosted as `inputAccessoryView`,
// which UIKit places in a UIKeyboardItemContainerView inside a separate,
// full-screen-width UITextEffectsWindow - independent of the owning view
// controller's own view/bounds. When a conversation is shown in the detail
// (right) column, the compose bar still spans the entire screen width.
//
// IMPORTANT: do not resize UIKeyboardItemContainerView itself (the
// "container"/`self` in the hook below) - changing ITS frame represents the
// keyboard accessory's frame to the system and triggers a keyboard
// frame-change notification, which MessagesViewController's keyboard handler
// reacts to by requesting another layout pass, which re-enters this hook -
// an infinite loop that freezes the app. Only resize the MessageInputBar
// subview within the container; that's purely cosmetic and doesn't represent
// "the keyboard moved".
static char kApolloMessageInputBarTargetKey;

%hook _TtC6Apollo22MessagesViewController

- (void)viewDidLayoutSubviews {
    %orig;

    UIViewController *selfVC = (UIViewController *)self;
    UIView *bar = selfVC.inputAccessoryView;
    if (!bar) return;

    UISplitViewController *split = selfVC.splitViewController;
    CGFloat targetX = 0, targetWidth = 0;
    if (split && split.displayMode == UISplitViewControllerDisplayModeOneBesideSecondary) {
        UINavigationController *detailNav = (UINavigationController *)[split viewControllerForColumn:UISplitViewControllerColumnSecondary];
        if (detailNav.topViewController == selfVC) {
            CGFloat splitWidth = split.view.bounds.size.width;
            UINavigationController *primaryNav = (UINavigationController *)[split viewControllerForColumn:UISplitViewControllerColumnPrimary];
            CGFloat primaryWidth = primaryNav.view.bounds.size.width;
            targetX = primaryWidth;
            targetWidth = splitWidth - primaryWidth;
        }
    }

    // Stash the desired frame for the UIKeyboardItemContainerView hook below,
    // which re-applies it whenever the container re-lays-out its subviews
    // (overriding the container's own full-width layout of the bar).
    objc_setAssociatedObject(bar, &kApolloMessageInputBarTargetKey,
        [NSValue valueWithCGRect:CGRectMake(targetX, 0, targetWidth, 0)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (bar.superview) {
        CGRect frame = bar.frame;
        CGFloat newX = (targetWidth > 0) ? targetX : 0;
        CGFloat newWidth = (targetWidth > 0) ? targetWidth : bar.superview.bounds.size.width;
        if (fabs(frame.origin.x - newX) > 0.5 || fabs(frame.size.width - newWidth) > 0.5) {
            frame.origin.x = newX;
            frame.size.width = newWidth;
            bar.frame = frame;
            // Scoped to the bar's own subtree - doesn't request a re-layout
            // of its superview/window, so this can't feed back into the
            // keyboard frame-change notification loop described above.
            [bar setNeedsLayout];
        }
    }
}

%end

%hook UIKeyboardItemContainerView

- (void)layoutSubviews {
    %orig;

    UIView *selfView = (UIView *)self;
    for (UIView *subview in selfView.subviews) {
        NSValue *target = objc_getAssociatedObject(subview, &kApolloMessageInputBarTargetKey);
        if (!target) continue;

        CGRect t = [target CGRectValue];
        CGFloat targetWidth = t.size.width;
        if (targetWidth <= 0) continue;
        CGFloat targetX = t.origin.x;

        CGRect frame = subview.frame;
        if (fabs(frame.origin.x - targetX) > 0.5 || fabs(frame.size.width - targetWidth) > 0.5) {
            frame.origin.x = targetX;
            frame.size.width = targetWidth;
            subview.frame = frame;
        }
    }
}

%end
