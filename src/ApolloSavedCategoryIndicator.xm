// ApolloSavedCategoryIndicator
//
// Recolors the bottom-right "saved" corner triangle on comment/post cells to
// the item's Saved Category color, with an SF Symbol composited inside when
// the category has one. See ApolloSavedCategoryAppearance.{h,m} for the
// appearance side-store and the reverse (item -> category) lookup this reads.
//
// ── Mechanism (RE'd in Hopper; refined against observed sim behavior) ──────
// savedIndicatorNode (an ASImageNode) is a plain stock asset —
// "saved-triangle-small" on CommentCellNode/CompactPostCellNode,
// "saved-triangle" on LargePostCellNode. No procedural drawing anywhere.
// Apollo colors it at draw time via
//   [savedIndicatorNode setImageModificationBlock:ASImageNodeTintColorModificationBlock(color)]
// with a hardcoded hex (#07BE00 light / #00940F dark), called from each
// class's own theme-apply function.
//
// An earlier version of this file tried to win the *color-only* case purely
// by intercepting that setter and substituting a different tint block,
// reasoning from the Hopper call graph that the theme-apply function fires on
// every layout pass. In the simulator that didn't hold: color-only categories
// stayed stock green, while categories with BOTH a color and an icon rendered
// correctly. The actual difference was that the icon path bakes color+glyph
// directly into `.image` from -didEnterVisibleState (which reliably runs with
// the cell's model already bound) and explicitly clears the modification
// block — so whatever Apollo's setter-call timing actually is stopped
// mattering for that path. Fix: always bake through -didEnterVisibleState,
// for the color-only case too (an icon-less composite is just the stock
// asset filled with the category color, which ApolloSavedCategoryTriangleImage
// already produces when `symbolName` is nil). Falls back to reproducing
// Apollo's own stock green when there's no custom appearance, rather than
// leaving it to Apollo's own reapplication — same reasoning, made unconditional.
//
// -[ASImageNode setImageModificationBlock:] is still hooked, but now purely as
// a live backstop: if Apollo reinstalls its own tint *after* our bake (e.g. a
// live light/dark trait change while the cell is already on screen), a
// category with a custom color would otherwise get double-tinted back toward
// green. The hook just swallows that reinstallation for nodes we own; it no
// longer tries to construct or substitute a replacement block itself.
// setImageModificationBlock: is already hooked once elsewhere in this tweak
// (ApolloThemeRuntime.xm, for the vote-arrow accent-color option), narrowly
// scoped to DualStateButtonNode's iconNode with an unconditional %orig
// fallthrough. ASTextNode/ASImageNode being %hook'd from multiple files is an
// established pattern in this codebase (nine other files hook ASTextNode
// alone) — Logos chains same-selector hooks across files safely as long as
// each scopes itself and falls through via %orig, which both do here.
//
// CompactPostCellNode's savedIndicatorNode is `ASImageNode?` and only
// allocated once the item is actually saved; the other two classes always
// allocate it in -init — ApolloSavedCategoryApplyAppearance tolerates nil.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloSavedCategoryAppearance.h"

// Deliberately not importing Tweak.h: it already declares its own minimal
// `ASImageNode : NSObject` (just +createContentsForkey:drawParameters:isCancelled:,
// for a different consumer), which would collide with the richer local
// ASImageNode/ASDisplayNode pair this file needs — the exact hazard
// ApolloTextureDecls.h's header comment warns about. RDKLink/RDKComment are
// forward-declared locally instead, mirroring the existing convention of each
// file declaring only the slice of these models it actually touches (e.g.
// ApolloCommentsCollapse.xm's own local `RDKComment : NSObject`).
@interface RDKLink : NSObject
@property (copy, nonatomic, readonly) NSString *fullName;
@end

@interface RDKComment : NSObject
@property (copy, nonatomic, readonly) NSString *fullName;
@end

// Minimal local Texture forward declarations — mirrors ApolloThemeRuntime.xm's
// copy of this same minimal pair (also deliberately not importing the shared
// ApolloTextureDecls.h, for the same reason as above: several files declare
// their own differently-shaped copies of these class names on purpose).
@class ASDisplayNode;
@interface ASDisplayNode : NSObject
- (ASDisplayNode *)supernode;
- (UIView *)view;
@end

@interface ASImageNode : ASDisplayNode
@property (nonatomic, strong) UIImage *image;
- (void)setImageModificationBlock:(id)block;
@end

#pragma mark - Stock asset lookup

// Apollo's own bundled asset — loaded via plain +imageNamed: (no explicit
// bundle), the same way ApolloMedia.xm pulls "video-player-airplay" out of
// Apollo's own Assets.car. Cached once; both are tiny and effectively static
// for the process lifetime.
static UIImage *ApolloSavedCategoryStockAsset(BOOL smallVariant) {
    static UIImage *smallAsset;
    static UIImage *largeAsset;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        smallAsset = [UIImage imageNamed:@"saved-triangle-small"];
        largeAsset = [UIImage imageNamed:@"saved-triangle"];
    });
    return smallVariant ? smallAsset : largeAsset;
}

#pragma mark - Category resolution for a cell

// CommentCellNode holds `comment` (RDKComment), LargePostCellNode/
// CompactPostCellNode hold `link` (RDKLink) — both are plain ObjC-object
// ivars (RDKThing subclasses), so a generic ivar-by-name read covers all
// three without per-class branching. Returns nil for an uncategorized (or
// unsaved) item.
static NSString *ApolloSavedCategoryForCell(id cell) {
    if (!cell) return nil;
    RDKComment *comment = ApolloReadObjectIvar(cell, "comment");
    NSString *fullName = comment.fullName;
    if (fullName.length == 0) {
        RDKLink *link = ApolloReadObjectIvar(cell, "link");
        fullName = link.fullName;
    }
    return fullName.length > 0 ? ApolloSavedCategoryForItemID(fullName) : nil;
}

#pragma mark - Backstop: swallow a later reapplication of Apollo's own tint

%hook ASImageNode

- (void)setImageModificationBlock:(id)block {
    // Scope by identity, not by supernode class: reading a nonexistent ivar
    // name off an unrelated node returns nil (ApolloReadObjectIvar's offset
    // guard), so this is naturally a no-op for every ASImageNode on screen
    // that isn't literally one of the three saved-indicator nodes.
    id supernode = [(ASDisplayNode *)self supernode];
    id savedIndicatorNode = supernode ? ApolloReadObjectIvar(supernode, "savedIndicatorNode") : nil;
    if (savedIndicatorNode != self) {
        %orig;
        return;
    }

    NSString *category = ApolloSavedCategoryForCell(supernode);
    ApolloSavedCategoryAppearance *appearance = category ? ApolloSavedCategoryAppearanceFor(category) : nil;
    if (appearance) {
        // -didEnterVisibleState already baked this node's image — color (custom
        // or, for an icon-only category, Apollo's own stock green) plus glyph
        // if any. Any tint Apollo applies on top would re-flatten that bake:
        // for a custom color it drags it back toward green, and for an
        // icon-only category (stock green fill, custom glyph) it would tint
        // the glyph pixels green too, since a tint block colors by alpha mask
        // with no notion of "this part is the glyph." Swallow it either way.
        %orig(nil);
        return;
    }
    // No custom appearance at all — our own bake already reproduces Apollo's
    // exact stock green with no glyph, so whatever Apollo installs here
    // changes nothing visible; let it through unmodified.
    %orig;
}

%end

#pragma mark - Bake color (+ optional glyph) into the image itself

// Shared by all three %hook blocks below. `stockSmall` selects which of
// Apollo's two triangle assets this class uses. Always ends with the node's
// `.image` fully representing the correct on-screen color (custom or stock)
// and `imageModificationBlock` cleared, so the visible result never depends
// on if/when Apollo's own theme-apply function happens to run.
static void ApolloSavedCategoryApplyAppearance(id cell, BOOL stockSmall) {
    ASImageNode *node = ApolloReadObjectIvar(cell, "savedIndicatorNode");
    if (!node) return; // not saved (CompactPostCellNode never allocates the node otherwise)

    UIImage *stockAsset = ApolloSavedCategoryStockAsset(stockSmall);
    if (!stockAsset) return;

    NSString *category = ApolloSavedCategoryForCell(cell);
    ApolloSavedCategoryAppearance *appearance = category ? ApolloSavedCategoryAppearanceFor(category) : nil;

    UITraitCollection *traits = [(ASDisplayNode *)cell view].traitCollection;
    // An icon-only category (no custom color set) still renders on Apollo's
    // own stock green — "custom icon, default color" is a real, supported
    // combination, not just an intermediate state on the way to a custom color.
    UIColor *color = appearance.color ?: ApolloSavedCategoryDefaultColor(traits);
    NSString *symbol = appearance.symbolName;

    UIImage *composite = ApolloSavedCategoryTriangleImage(stockAsset, color, symbol, traits);
    [node setImage:composite];
    [node setImageModificationBlock:nil];
}

%hook _TtC6Apollo15CommentCellNode
- (void)didEnterVisibleState {
    %orig;
    ApolloSavedCategoryApplyAppearance(self, YES);
}
%end

%hook _TtC6Apollo17LargePostCellNode
- (void)didEnterVisibleState {
    %orig;
    ApolloSavedCategoryApplyAppearance(self, NO);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)didEnterVisibleState {
    %orig;
    ApolloSavedCategoryApplyAppearance(self, YES);
}
%end
