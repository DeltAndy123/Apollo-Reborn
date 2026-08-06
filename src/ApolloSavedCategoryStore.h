// ApolloSavedCategoryStore.{h,m}
//
// Single owner of reading/writing Apollo's own SavedItemsCategoriesDatabase
// JSON (group.com.christianselig.apollo suite, key
// "SavedItemsCategoriesDatabase": {"categories": {name: [itemID]}}) from
// tweak-owned UI. SavedCategoriesViewController's list/add/swipe actions and
// ApolloSavedCategoryEditorViewController's name row both go through here,
// rather than each re-implementing name validation and duplicate checking —
// exactly the kind of divergence-over-time risk this file exists to avoid.
//
// Extracted from what used to be private methods on SavedCategoriesViewController
// once a second screen (the editor) needed the same rename path.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Case-insensitive sorted category names.
FOUNDATION_EXPORT NSArray<NSString *> *ApolloSavedCategoryNames(void);

// Trimmed length >= 3 — the same bar SavedCategoriesViewController always
// enforced. Does not check for duplicates (that's a submit-time check, in
// Add/Rename below, not a live-typing one).
FOUNDATION_EXPORT BOOL ApolloSavedCategoryNameIsValid(NSString *_Nullable name);

// Adds a new empty category. Returns NO and sets *outError (suitable for
// showing directly to the user) on an invalid or case-insensitive-duplicate
// name; does not touch appearance.
FOUNDATION_EXPORT BOOL ApolloSavedCategoryAdd(NSString *name, NSString *_Nullable *_Nullable outError);

// Renames a category, carrying its saved-item list and its appearance entry
// (if any, via ApolloSavedCategoryRenameAppearance) to the new name. A no-op
// success if newName trims to the same value as oldName. Returns NO and sets
// *outError on an invalid, duplicate, or missing-oldName name.
FOUNDATION_EXPORT BOOL ApolloSavedCategoryRename(NSString *oldName, NSString *newName, NSString *_Nullable *_Nullable outError);

// Deletes a category (its saved items are untouched) and its appearance entry.
FOUNDATION_EXPORT void ApolloSavedCategoryDelete(NSString *name);

NS_ASSUME_NONNULL_END
