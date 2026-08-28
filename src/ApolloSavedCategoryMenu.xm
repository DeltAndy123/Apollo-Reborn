// ApolloSavedCategoryMenu
//
// Adds a "Category: <name>" row that opens a Saved Category picker, on BOTH of
// a post's/comment's menus:
//
//   • the "..." action menu   — via ApolloActionMenu's declarative registry
//   • the long-press menu     — via the UIContextMenuConfiguration factory
//
// These are genuinely separate menus built by unrelated machinery, so they need
// separate injection; they share this file's picker, row label/icon helpers,
// and saved-item gating so the two can't drift. Companion to
// ApolloSavedCategoryIndicator.xm (which renders the category on the cell's
// corner triangle) and ApolloSavedCategoryStore.{h,m} (which owns the writes).
//
// ── Why the "..." path needs a capture (the long-press one doesn't) ────────
// The row itself goes through ApolloActionMenu's declarative registry, which
// is the single owner of _TtC6Apollo16ActionController's table methods on the
// legacy sheet and of the Liquid Glass UIMenu conversion (see ApolloActionMenu.h
// — a second hook on that class is the PR #570 desync bug class). One spec
// therefore covers BOTH rendering paths.
//
// But a spec's blocks only receive `actionController` and `menuTitle`, and
// ActionController holds NO reference to the post/comment it was opened for —
// its ivars are purely presentational (tableView, actionsDescription, actions,
// actionHandlers; see Headers/ObjC/_TtC6Apollo16ActionController.h). So the
// model has to be captured on the way in, from the cell whose "..." was
// tapped. Those tap handlers ARE ObjC-visible, unlike most of the cells' Swift
// methods:
//
//     LargePostCellNode / CompactPostCellNode -> moreOptionsButtonTappedWithSender:
//     CommentCellNode                         -> moreOptionsTappedWithSender:      (note: different selector)
//
// ApolloNativeActionMenus.xm already brackets these same selectors to capture a
// popover source view, so the pattern is established; it stashes only the view
// (and only under Liquid Glass), hence our own ungated capture of the model.
//
// The captured item is latched onto the controller inside `matches`, which
// ApolloActionMenu documents as being called once per controller and memoized —
// explicitly the place for one-shot claiming. That matters because the capture
// window closes when the tap handler returns, while `title`/`perform` run later
// (and repeatedly), so they must read the latched value, never the live capture.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloActionMenu.h"
#import "ApolloSavedCategoryAppearance.h"
#import "ApolloSavedCategoryStore.h"

// Local model declarations — Tweak.h's own RDKLink lacks `saved`, and pulling
// it in here would collide with the richer local decls this file needs (same
// reasoning as ApolloSavedCategoryIndicator.xm's header comment).
@interface RDKLink : NSObject
@property (copy, nonatomic, readonly) NSString *fullName;
@property (nonatomic, readonly) BOOL saved;
@end

@interface RDKComment : NSObject
@property (copy, nonatomic, readonly) NSString *fullName;
@property (nonatomic, readonly) BOOL saved;
@end

// File scope, not inside the %group below: Logos hoists hook method signatures
// out of the group when it generates their implementations, so a typedef used
// in a hooked method's signature has to be visible at file scope.
typedef UIMenu * (^ApolloSCMenuProvider)(NSArray<UIMenuElement *> *suggestedActions);

#pragma mark - Capture (tap handler -> menu build)

// Live only for the duration of a "..." tap handler. `matches` latches it onto
// the controller; nothing else may read it.
static __weak id sCapturedCell = nil;

static const void *kApolloSCMenuItemKey = &kApolloSCMenuItemKey;

// Reads an object's model ivar and returns its fullname if (and only if) the
// item is saved. Deliberately name-based rather than class-based, because the
// same two ivar names cover every owner both entry points care about —
// ApolloReadObjectIvar returns nil for a name the class doesn't have:
//
//   `comment` (RDKComment):  CommentCellNode, CommentSectionController
//   `link`    (RDKLink):     LargePostCellNode, CompactPostCellNode,
//                            PostCellActionTaker, CommentsHeaderSectionController
static NSString *ApolloSCMenuSavedFullNameForCell(id cell) {
    if (!cell) return nil;

    RDKComment *comment = ApolloReadObjectIvar(cell, "comment");
    if (comment) {
        // Category membership is only coherent for an item that's actually
        // saved — Apollo's schema is category -> [savedItemID].
        return comment.saved ? comment.fullName : nil;
    }
    RDKLink *link = ApolloReadObjectIvar(cell, "link");
    if (link) {
        return link.saved ? link.fullName : nil;
    }
    return nil;
}

#pragma mark - Picker

static UIViewController *ApolloSCMenuTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow) { keyWindow = window; break; }
        if (!keyWindow) keyWindow = window;
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// A category's row image in the picker — the same triangle render the cell
// corner and the settings list use, so the three always agree.
static UIImage *ApolloSCMenuCategoryImage(NSString *categoryName, UITraitCollection *traits) {
    ApolloSavedCategoryAppearance *appearance = ApolloSavedCategoryAppearanceFor(categoryName);
    if (!appearance) return nil;
    UIColor *color = appearance.color ?: ApolloSavedCategoryDefaultColor(traits);
    return ApolloSavedCategoryTriangleImage([UIImage imageNamed:@"saved-triangle-small"],
                                            color, appearance.symbolName, traits);
}

// Row label, shared by the "..." spec and the long-press UIAction so the two
// entry points can never drift apart.
static NSString *ApolloSCMenuRowTitleForItem(NSString *fullName) {
    NSString *current = fullName.length > 0 ? ApolloSavedCategoryForItemID(fullName) : nil;
    return current.length > 0 ? [NSString stringWithFormat:@"Category: %@", current] : @"Set Category";
}

// Row icon: the category's own swatch when it has a custom appearance, else a
// plain symbol (there's nothing meaningful to render a swatch from).
static UIImage *ApolloSCMenuRowImageForItem(NSString *fullName, UITraitCollection *traits) {
    NSString *current = fullName.length > 0 ? ApolloSavedCategoryForItemID(fullName) : nil;
    UIImage *swatch = current.length > 0 ? ApolloSCMenuCategoryImage(current, traits) : nil;
    return swatch ?: [UIImage systemImageNamed:@"folder"];
}

static void ApolloSCMenuPresentPicker(NSString *fullName) {
    if (fullName.length == 0) return;

    NSArray<NSString *> *categories = ApolloSavedCategoryNames();
    NSString *current = ApolloSavedCategoryForItemID(fullName);

    UIViewController *presenter = ApolloSCMenuTopViewController();
    if (!presenter) {
        ApolloLog(@"[SavedCategoryMenu] no presenter found; dropping picker for %@", fullName);
        return;
    }

    if (categories.count == 0) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"No Saved Categories"
            message:@"Create a category first in Apollo Reborn settings under Saved Categories."
            preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:empty animated:YES completion:nil];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Saved Category"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *name in categories) {
        BOOL isCurrent = [name isEqualToString:current];
        // Matches the "(Current)" convention the tweak's other pickers use
        // (see ApolloSettingsPresentPicker in settings/ApolloSettingsForm).
        NSString *title = isCurrent ? [NSString stringWithFormat:@"%@ (Current)", name] : name;
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            ApolloSavedCategorySetItemCategory(fullName, name);
            ApolloLog(@"[SavedCategoryMenu] %@ -> category '%@'", fullName, name);
        }];
        UIImage *image = ApolloSCMenuCategoryImage(name, presenter.traitCollection);
        if (image && [action respondsToSelector:@selector(setImage:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(action, @selector(setImage:), image);
        }
        [sheet addAction:action];
    }

    if (current.length > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove from Category" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            ApolloSavedCategorySetItemCategory(fullName, nil);
            ApolloLog(@"[SavedCategoryMenu] %@ -> removed from '%@'", fullName, current);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // iPad: an unanchored action sheet is a hard crash. Anchor to the
    // presenter's own view centre — we no longer have the tapped "..." button
    // by this point (the sheet that owned it has already dismissed).
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = presenter.view;
        sheet.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 0, 0);
        sheet.popoverPresentationController.permittedArrowDirections = 0;
    }

    [presenter presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Tap capture hooks

%group SavedCategoryMenu

%hook _TtC6Apollo17LargePostCellNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    sCapturedCell = self;
    %orig;
    sCapturedCell = nil;
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    sCapturedCell = self;
    %orig;
    sCapturedCell = nil;
}
%end

// Note the selector differs from the post cells' — comment cells use
// moreOptionsTappedWithSender: (no "Button").
%hook _TtC6Apollo15CommentCellNode
- (void)moreOptionsTappedWithSender:(id)sender {
    sCapturedCell = self;
    %orig;
    sCapturedCell = nil;
}
%end

#pragma mark - Long-press context menu

// Set only while one of the bracketed contextMenuInteraction: delegate calls
// below is on the stack, which is when Apollo builds that menu's
// UIContextMenuConfiguration. Saved/restored rather than just cleared, so a
// nested build (crosspost cell action taker inside a comments header) can't
// blow away the outer value.
static NSString *sContextMenuFullName = nil;

// Unlike the "..." path, no capture-and-latch is needed here: these delegate
// objects OWN the model (PostCellActionTaker.link,
// CommentSectionController.comment, CommentsHeaderSectionController.link), so
// `self` is all we need.
//
// The three hooks below are deliberately written out rather than shared via a
// macro: Logos rewrites %orig during its own textual pass, before the C
// preprocessor expands macros, so a %orig inside a #define fails to build
// ("%orig does not make sense outside a function"). ApolloNativeActionMenus.xm
// repeats the same bracket across these same classes for the same reason.

%hook _TtC6Apollo19PostCellActionTaker
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    NSString *previous = sContextMenuFullName;
    sContextMenuFullName = ApolloSCMenuSavedFullNameForCell(self);
    UIContextMenuConfiguration *configuration = %orig;
    sContextMenuFullName = previous;
    return configuration;
}
%end

%hook _TtC6Apollo24CommentSectionController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    NSString *previous = sContextMenuFullName;
    sContextMenuFullName = ApolloSCMenuSavedFullNameForCell(self);
    UIContextMenuConfiguration *configuration = %orig;
    sContextMenuFullName = previous;
    return configuration;
}
%end

// The post shown at the top of a comments thread.
%hook _TtC6Apollo31CommentsHeaderSectionController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    NSString *previous = sContextMenuFullName;
    sContextMenuFullName = ApolloSCMenuSavedFullNameForCell(self);
    UIContextMenuConfiguration *configuration = %orig;
    sContextMenuFullName = previous;
    return configuration;
}
%end

// Appends our row to the long-press menu by wrapping the config's action
// provider at construction time — the same technique ApolloNativeActionMenus.xm
// and ApolloSavedCategories.xm already use on this factory. Scoped by
// sContextMenuFullName, so it only ever fires for the three delegates above and
// never for the "..." menu (which is built from an ActionController, not here).
//
// Ordering note: this is now the third wrapper on this method. They compose
// safely because ApolloNativeActionMenuTransformMenu styles the menu IN PLACE
// and returns the same object rather than rebuilding it, so whichever order
// Logos chains them in, our appended action survives. If our wrapper runs
// inside the LG one, our action also picks up its styling; if outside, the row
// still appears, just unstyled.
%hook UIContextMenuConfiguration

+ (instancetype)configurationWithIdentifier:(id<NSCopying>)identifier previewProvider:(id)previewProvider actionProvider:(ApolloSCMenuProvider)actionProvider {
    NSString *fullName = sContextMenuFullName;
    if (fullName.length == 0 || !actionProvider) {
        return %orig;
    }

    ApolloSCMenuProvider originalProvider = [actionProvider copy];
    ApolloSCMenuProvider wrapped = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIMenu *menu = originalProvider(suggestedActions);
        if (![menu isKindOfClass:[UIMenu class]]) return menu;

        UIAction *categoryAction =
            [UIAction actionWithTitle:ApolloSCMenuRowTitleForItem(fullName)
                                image:ApolloSCMenuRowImageForItem(fullName, nil)
                           identifier:nil
                              handler:^(__unused __kindof UIAction *action) {
            // Let the context menu's dismissal animation finish before our
            // picker goes up, matching the "..." path's own delay.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloSCMenuPresentPicker(fullName);
            });
        }];

        NSMutableArray<UIMenuElement *> *children = [menu.children mutableCopy] ?: [NSMutableArray array];
        [children addObject:categoryAction];
        return [UIMenu menuWithTitle:menu.title
                               image:menu.image
                          identifier:menu.identifier
                             options:menu.options
                            children:children];
    };

    return %orig(identifier, previewProvider, wrapped);
}

%end

%end // group

#pragma mark - Registration

%ctor {
    %init(SavedCategoryMenu);

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"SavedCategory";
    spec.placement = ApolloActionMenuPlacementAppend;
    spec.inlineSection = NO;
    spec.legacyDismissesSheet = YES;

    // Called once per controller and memoized — latch the captured item here,
    // while the tap handler's capture is still live. title/perform run later
    // (and repeatedly) and read only the latched value.
    spec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        (void)menuTitle;
        NSString *fullName = ApolloSCMenuSavedFullNameForCell(sCapturedCell);
        if (fullName.length == 0) return NO; // not a saved post/comment cell menu
        objc_setAssociatedObject(actionController, kApolloSCMenuItemKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return YES;
    };

    spec.title = ^NSString *(id actionController, UITableViewCell *donor) {
        (void)donor;
        NSString *fullName = objc_getAssociatedObject(actionController, kApolloSCMenuItemKey);
        if (fullName.length == 0) return nil;
        NSString *current = ApolloSavedCategoryForItemID(fullName);
        return current.length > 0 ? [NSString stringWithFormat:@"Category: %@", current] : @"Set Category";
    };

    spec.image = ^UIImage *(id actionController, UITableViewCell *donor) {
        (void)donor;
        NSString *fullName = objc_getAssociatedObject(actionController, kApolloSCMenuItemKey);
        NSString *current = fullName.length > 0 ? ApolloSavedCategoryForItemID(fullName) : nil;
        UIImage *categoryImage = current.length > 0
            ? ApolloSCMenuCategoryImage(current, ((UIViewController *)actionController).traitCollection)
            : nil;
        // Falls back to a plain symbol for a category with no custom
        // appearance (nothing meaningful to render as a swatch).
        return categoryImage ?: [UIImage systemImageNamed:@"folder"];
    };

    spec.perform = ^(id actionController) {
        NSString *fullName = objc_getAssociatedObject(actionController, kApolloSCMenuItemKey);
        if (fullName.length == 0) return;
        // Let the sheet's / context menu's dismissal animation finish before
        // presenting ours, mirroring ApolloDeletedCommentsMenu's own delay.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloSCMenuPresentPicker(fullName);
        });
    };

    ApolloActionMenuRegister(spec);
    ApolloLog(@"[SavedCategoryMenu] saved-category menu spec registered");
}
