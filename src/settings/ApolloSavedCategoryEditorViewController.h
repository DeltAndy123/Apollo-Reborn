#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Full "Edit Category" page for one Saved Category: name (rename inline),
// corner-indicator color + curated-SF-Symbol icon (see
// ApolloSavedCategoryAppearance.{h,m}), and a way to clear back to default
// appearance. Pushed by tapping a row in SavedCategoriesViewController.
// Persists directly on Done/Remove — there's no separate caller-side commit
// step; the presenting list re-reads on -viewWillAppear.
@interface ApolloSavedCategoryEditorViewController : UITableViewController

- (instancetype)initWithCategoryName:(NSString *)categoryName;

@end

NS_ASSUME_NONNULL_END
