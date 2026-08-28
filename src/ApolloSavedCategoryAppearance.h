// ApolloSavedCategoryAppearance.{h,m}
//
// Per-category color + SF Symbol icon for Apollo's Saved Categories, plus the
// machinery to surface it on the bottom-right "saved" corner indicator.
//
// Apollo's own SavedItemsCategoriesDatabase (name -> [itemID] JSON, persisted
// in the group.com.christianselig.apollo NSUserDefaults suite) is a native
// Swift struct with no room for extra fields, and Apollo never consults it at
// cell-render time. This module owns two things layered on top of it:
//
//   1. A side-store, keyed by category name, holding {color, symbol} — rides
//      standardUserDefaults under UDKeySavedCategoryAppearance.
//   2. A cached reverse index (item fullname -> category name) built from
//      Apollo's own group-suite JSON, so a cell can resolve its category with
//      one dictionary lookup instead of decoding JSON per cell. Item IDs in
//      that JSON are Reddit fullnames (t3_.../t1_...) stored verbatim — see
//      RDKThing.fullName, which is exactly what the tweak reads off a saved
//      post/comment's model.
//
// An item can sit in more than one category; the reverse index resolves the
// alphabetically-first category name when building the index, so the winner
// is deterministic across launches rather than depending on JSON key order.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// One category's custom look. Both fields nil means "no custom appearance
// set" — callers should fall back to Apollo's stock indicator in that case.
@interface ApolloSavedCategoryAppearance : NSObject
@property(nonatomic, copy, nullable) UIColor *color;
@property(nonatomic, copy, nullable) NSString *symbolName; // SF Symbol name, e.g. "star.fill"
@end

// Curated SF Symbol names offered by the category icon picker. Deliberately a
// fixed list, not full symbol search — see the plan's rationale (renders
// cleanly at the corner-triangle's tiny size, no giant name list to ship).
FOUNDATION_EXPORT NSArray<NSString *> *ApolloSavedCategorySymbolChoices(void);

// Reads the stored appearance for `name`, or nil if none has been set.
FOUNDATION_EXPORT ApolloSavedCategoryAppearance *_Nullable ApolloSavedCategoryAppearanceFor(NSString *name);

// Sets (or clears, passing nil for both) the appearance for `name`.
FOUNDATION_EXPORT void ApolloSavedCategorySetAppearance(NSString *name, UIColor *_Nullable color, NSString *_Nullable symbolName);

// Carries a category's appearance entry to a new name (used when the Saved
// Categories screen renames a category) or drops it (used on delete). Both
// are no-ops if `name` has no stored appearance.
FOUNDATION_EXPORT void ApolloSavedCategoryRenameAppearance(NSString *oldName, NSString *newName);
FOUNDATION_EXPORT void ApolloSavedCategoryRemoveAppearance(NSString *name);

// Reverse lookup: given a saved item's Reddit fullname (t3_.../t1_...),
// returns the category it belongs to, or nil if it's uncategorized. Backed by
// a cached index over Apollo's group-suite categories JSON; the cache
// invalidates itself on writes to that suite (including from Apollo's own
// native category UI) and on iCloud KVS sync, so callers don't need to manage
// staleness.
FOUNDATION_EXPORT NSString *_Nullable ApolloSavedCategoryForItemID(NSString *fullName);

// Forces the next ApolloSavedCategoryForItemID() call to rebuild its index.
// The index self-invalidates on NSUserDefaults / iCloud-KVS change
// notifications, but this tweak's own writes need the *next* read to be
// correct synchronously (the "..." menu redraws an item's category right after
// changing it), so ApolloSavedCategoryStore calls this on every write.
FOUNDATION_EXPORT void ApolloSavedCategoryInvalidateItemIndex(void);

// Apollo's own stock corner-indicator color (Hopper: sub_100752f2c decoding
// Swift small strings "07BE00"/"00940F", selected by a dark-mode bool).
// Shared by the indicator hook (a category with an icon but no custom color
// still renders on this, rather than depending on Apollo's own tint
// reapplication timing) and the settings preview (so "Default (Green)" shows
// exactly what will actually render).
FOUNDATION_EXPORT UIColor *ApolloSavedCategoryDefaultColor(UITraitCollection *_Nullable traits);

// Renders the corner "saved" indicator: `baseAsset` (Apollo's own
// "saved-triangle" or "saved-triangle-small" image, passed in so the caller
// controls exactly which asset/size is being replaced) filled with `color`
// and, if `symbolName` is non-nil, the glyph composited on top in a contrasting
// color chosen by ApolloColorIsLight(). Result is NSCache'd by asset identity +
// color + symbol + trait collection, mirroring ApolloSettingsIconTileImage's
// caching (settings/ApolloSettingsForm.m). Returns `baseAsset` unmodified if
// `color` is nil.
FOUNDATION_EXPORT UIImage *ApolloSavedCategoryTriangleImage(UIImage *baseAsset, UIColor *_Nullable color, NSString *_Nullable symbolName, UITraitCollection *_Nullable traits);

NS_ASSUME_NONNULL_END
