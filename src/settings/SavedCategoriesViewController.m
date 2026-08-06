#import "settings/SavedCategoriesViewController.h"
#import "settings/ApolloSavedCategoryEditorViewController.h"
#import "ApolloSavedCategoryAppearance.h"
#import "ApolloSavedCategoryStore.h"

@implementation SavedCategoriesViewController

#pragma mark - Helpers

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)reloadCategories {
    _categoryNames = ApolloSavedCategoryNames();
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)presentEditorForName:(NSString *)name {
    ApolloSavedCategoryEditorViewController *editor = [[ApolloSavedCategoryEditorViewController alloc] initWithCategoryName:name];
    [self.navigationController pushViewController:editor animated:YES];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Saved Categories";
    _categoryNames = ApolloSavedCategoryNames();

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addCategory)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Catches both a rename/delete made elsewhere and a return from the
    // editor, which persists directly rather than calling back —
    // reloadCategories also re-renders each row's name and swatch from
    // current storage.
    [self reloadCategories];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _categoryNames.count > 0 ? (NSInteger)_categoryNames.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_categoryNames.count == 0) {
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Cat_Empty"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Cat_Empty"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.textLabel.text = @"No saved categories";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Cat_Item"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Cat_Item"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSString *name = _categoryNames[indexPath.row];
    cell.textLabel.text = name;
    [self apollo_applyPrimaryTextColorToCell:cell];

    // Leading swatch previews exactly what the corner indicator on saved
    // items in this category will look like — same renderer, same asset.
    // Categories with no custom appearance at all show no swatch (stock
    // green, unchanged) rather than a placeholder, since there's nothing to
    // preview; an icon-only category (default green + custom glyph) still
    // gets one, since that combination is itself a custom appearance now.
    ApolloSavedCategoryAppearance *appearance = ApolloSavedCategoryAppearanceFor(name);
    if (appearance) {
        UIColor *color = appearance.color ?: ApolloSavedCategoryDefaultColor(self.traitCollection);
        cell.imageView.image = ApolloSavedCategoryTriangleImage([UIImage imageNamed:@"saved-triangle-small"],
                                                                  color, appearance.symbolName, self.traitCollection);
    } else {
        cell.imageView.image = nil;
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_categoryNames.count == 0) return;
    [self presentEditorForName:_categoryNames[indexPath.row]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_categoryNames.count == 0) return nil;

    NSString *name = _categoryNames[indexPath.row];

    UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"Rename"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self renameCategoryWithName:name];
            completionHandler(YES);
        }];
    renameAction.backgroundColor = [UIColor systemBlueColor];

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"Delete"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self deleteCategoryWithName:name];
            completionHandler(YES);
        }];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, renameAction]];
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return _categoryNames.count > 0;
}

#pragma mark - Saved Categories CRUD

- (void)addCategory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Saved Category"
        message:nil
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Category Name";
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *addAction = [UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = alert.textFields.firstObject.text;
        NSString *error = nil;
        if (!ApolloSavedCategoryAdd(name, &error)) {
            [self showAlertWithTitle:@"Name Already Used" message:error];
            return;
        }
        [self reloadCategories];
    }];

    // Disable "Add" until input is non-empty
    addAction.enabled = NO;
    __weak UIAlertController *weakAlert = alert;
    [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidChangeNotification
        object:alert.textFields.firstObject
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            NSString *text = weakAlert.textFields.firstObject.text;
            addAction.enabled = ApolloSavedCategoryNameIsValid(text);
        }];

    [alert addAction:cancelAction];
    [alert addAction:addAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)renameCategoryWithName:(NSString *)oldName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Category"
        message:nil
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = oldName;
        textField.placeholder = @"Category Name";
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *renameAction = [UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newName = alert.textFields.firstObject.text;
        NSString *error = nil;
        if (!ApolloSavedCategoryRename(oldName, newName, &error)) {
            [self showAlertWithTitle:@"Name Already Used" message:error];
            return;
        }
        [self reloadCategories];
    }];

    // Disable "Rename" until input is non-empty
    renameAction.enabled = ApolloSavedCategoryNameIsValid(oldName);
    __weak UIAlertController *weakAlert = alert;
    [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidChangeNotification
        object:alert.textFields.firstObject
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            NSString *text = weakAlert.textFields.firstObject.text;
            renameAction.enabled = ApolloSavedCategoryNameIsValid(text);
        }];

    [alert addAction:cancelAction];
    [alert addAction:renameAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteCategoryWithName:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Category"
        message:[NSString stringWithFormat:@"Are you sure you want to delete \"%@\"? Items saved to this category will not be deleted.", name]
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *deleteAction = [UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        ApolloSavedCategoryDelete(name);
        [self reloadCategories];
    }];

    [alert addAction:cancelAction];
    [alert addAction:deleteAction];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
