#import "settings/ApolloSavedCategoryEditorViewController.h"
#import "ApolloCommon.h"
#import "ApolloSavedCategoryAppearance.h"
#import "ApolloSavedCategoryStore.h"

typedef NS_ENUM(NSInteger, ApolloSCESection) {
    ApolloSCESectionName = 0,
    ApolloSCESectionPreview,
    ApolloSCESectionColor,
    ApolloSCESectionIcon,
    ApolloSCESectionRemove,
    ApolloSCESectionCount,
};

// Color row indices within ApolloSCESectionColor — mirrors the Icon section's
// "None" + choices shape, so "custom icon, default color" is a first-class,
// explicitly reachable combination rather than something only achievable by
// never touching the Color row.
typedef NS_ENUM(NSInteger, ApolloSCEColorRow) {
    ApolloSCEColorRowDefault = 0,
    ApolloSCEColorRowCustom,
    ApolloSCEColorRowCount,
};

@interface ApolloSavedCategoryEditorViewController () <UIColorPickerViewControllerDelegate, UITextFieldDelegate>
// The category's name as of last successful persist — updates in place on a
// successful rename so a subsequent appearance save uses the right key.
@property (nonatomic, copy) NSString *categoryName;
// nil means "Default (Green)" — a real, persisted choice, not just an unset
// scratch value. Picking a color in the picker is what turns this non-nil.
@property (nonatomic, strong, nullable) UIColor *selectedColor;
@property (nonatomic, copy, nullable) NSString *selectedSymbol;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UITextField *nameTextField;
@end

@implementation ApolloSavedCategoryEditorViewController

- (instancetype)initWithCategoryName:(NSString *)categoryName {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _categoryName = [categoryName copy];
        ApolloSavedCategoryAppearance *existing = ApolloSavedCategoryAppearanceFor(categoryName);
        _selectedColor = existing.color;
        _selectedSymbol = existing.symbolName;
    }
    return self;
}

// What actually gets rendered right now — the custom color if one is picked,
// otherwise Apollo's own stock green. Preview and persistence both go through
// this so "Default (Green)" in the list matches the corner exactly.
- (UIColor *)effectiveColor {
    return self.selectedColor ?: ApolloSavedCategoryDefaultColor(self.traitCollection);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Edit Category";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];
    // Can't go through -updateDoneEnabled yet: the Name row's cell (and so
    // nameTextField) hasn't been built by the table view at this point in the
    // lifecycle, so it would read a nil text field and disable Done until the
    // user edited the name field at least once, regardless of category state.
    // The category's existing name is already valid, so seed straight from it.
    self.navigationItem.rightBarButtonItem.enabled = ApolloSavedCategoryNameIsValid(self.categoryName);
}

#pragma mark - Preview

// Large-post-cell triangle asset — bigger and clearer for a preview than the
// small comment/compact variant; both render through the same function, so
// what's shown here matches the corner exactly in color and glyph placement,
// just at a bigger scale.
- (UIImage *)previewBaseAsset {
    return [UIImage imageNamed:@"saved-triangle"];
}

- (void)refreshPreview {
    UIImage *base = [self previewBaseAsset];
    self.previewImageView.image = ApolloSavedCategoryTriangleImage(base, [self effectiveColor], self.selectedSymbol, self.traitCollection);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloSCESectionColor] withRowAnimation:UITableViewRowAnimationNone];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloSCESectionIcon] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateDoneEnabled {
    self.navigationItem.rightBarButtonItem.enabled = ApolloSavedCategoryNameIsValid(self.nameTextField.text);
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloSCESectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloSCESectionName:    return 1;
        case ApolloSCESectionPreview: return 1;
        case ApolloSCESectionColor:   return ApolloSCEColorRowCount; // Default (Green) + Custom Color
        case ApolloSCESectionIcon:    return 1 + ApolloSavedCategorySymbolChoices().count; // "None" + curated symbols
        case ApolloSCESectionRemove:  return 1;
        default: return 0;
    }
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloSCESectionName:  return @"Name";
        case ApolloSCESectionColor: return @"Color";
        case ApolloSCESectionIcon:  return @"Icon";
        default: return nil;
    }
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloSCESectionColor) {
        return @"Shown on the corner of saved posts and comments in this category. Choose Default to keep the stock green — you can still pick a custom icon on its own.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case ApolloSCESectionName: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Name"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Name"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                self.nameTextField = [[UITextField alloc] initWithFrame:CGRectZero];
                self.nameTextField.text = self.categoryName;
                self.nameTextField.placeholder = @"Category Name";
                self.nameTextField.autocapitalizationType = UITextAutocapitalizationTypeWords;
                self.nameTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
                self.nameTextField.returnKeyType = UIReturnKeyDone;
                self.nameTextField.delegate = self;
                [self.nameTextField addTarget:self action:@selector(updateDoneEnabled) forControlEvents:UIControlEventEditingChanged];
                self.nameTextField.translatesAutoresizingMaskIntoConstraints = NO;
                [cell.contentView addSubview:self.nameTextField];
                UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
                [NSLayoutConstraint activateConstraints:@[
                    [self.nameTextField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                    [self.nameTextField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                    [self.nameTextField.topAnchor constraintEqualToAnchor:margins.topAnchor],
                    [self.nameTextField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
                ]];
            }
            return cell;
        }
        case ApolloSCESectionPreview: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Preview"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Preview"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
                self.previewImageView.contentMode = UIViewContentModeScaleAspectFit;
                self.previewImageView.translatesAutoresizingMaskIntoConstraints = NO;
                [cell.contentView addSubview:self.previewImageView];
                [NSLayoutConstraint activateConstraints:@[
                    [self.previewImageView.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor],
                    [self.previewImageView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:16],
                    [self.previewImageView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-16],
                    [self.previewImageView.widthAnchor constraintEqualToConstant:44],
                    [self.previewImageView.heightAnchor constraintEqualToConstant:44],
                ]];
                self.previewImageView.image = ApolloSavedCategoryTriangleImage([self previewBaseAsset], [self effectiveColor], self.selectedSymbol, self.traitCollection);
            }
            return cell;
        }
        case ApolloSCESectionColor: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Color"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Color"];
            }
            if (indexPath.row == ApolloSCEColorRowDefault) {
                cell.textLabel.text = @"Default (Green)";
                cell.imageView.image = [self swatchImageForColor:ApolloSavedCategoryDefaultColor(self.traitCollection)];
                cell.accessoryType = self.selectedColor ? UITableViewCellAccessoryNone : UITableViewCellAccessoryCheckmark;
            } else {
                cell.textLabel.text = @"Custom Color";
                cell.imageView.image = [self swatchImageForColor:self.selectedColor ?: [UIColor systemGray3Color]];
                cell.accessoryType = self.selectedColor ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            }
            return cell;
        }
        case ApolloSCESectionIcon: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Icon"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Icon"];
            }
            if (indexPath.row == 0) {
                cell.textLabel.text = @"None";
                cell.imageView.image = nil;
                cell.accessoryType = (self.selectedSymbol.length == 0) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            } else {
                NSString *symbol = ApolloSavedCategorySymbolChoices()[indexPath.row - 1];
                cell.textLabel.text = symbol;
                cell.imageView.image = [UIImage systemImageNamed:symbol];
                cell.imageView.tintColor = [UIColor labelColor];
                cell.accessoryType = [symbol isEqualToString:self.selectedSymbol] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            }
            return cell;
        }
        case ApolloSCESectionRemove: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Remove"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Remove"];
            }
            cell.textLabel.text = @"Remove Custom Appearance";
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            return cell;
        }
        default:
            return [UITableViewCell new];
    }
}

// A rounded color swatch for the Color row's leading image — mirrors
// ApolloLinkPreviewSettingsViewController's swatchImageForColor:.
- (UIImage *)swatchImageForColor:(UIColor *)color {
    CGSize size = CGSizeMake(26.0, 26.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1.0, 1.0, 24.0, 24.0) cornerRadius:6.0];
        [color setFill];
        [path fill];
        [[UIColor colorWithWhite:0.5 alpha:0.35] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case ApolloSCESectionColor:
            if (indexPath.row == ApolloSCEColorRowDefault) {
                self.selectedColor = nil;
                [self refreshPreview];
            } else {
                [self presentColorPicker];
            }
            break;
        case ApolloSCESectionIcon:
            self.selectedSymbol = (indexPath.row == 0) ? nil : ApolloSavedCategorySymbolChoices()[indexPath.row - 1];
            [self refreshPreview];
            break;
        case ApolloSCESectionRemove:
            [self removeTapped];
            break;
        default:
            break;
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Actions

- (void)presentColorPicker {
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.supportsAlpha = NO;
    picker.title = @"Category Color";
    // Seed from any already-chosen custom color; otherwise start from a
    // neutral pick rather than the stock green, since opening this picker at
    // all is the user declaring "I want something other than default".
    picker.selectedColor = self.selectedColor ?: [UIColor systemBlueColor];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)doneTapped {
    NSString *newName = [self.nameTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *renameError = nil;
    if (!ApolloSavedCategoryRename(self.categoryName, newName, &renameError)) {
        [self showAlertWithTitle:@"Name Already Used" message:renameError];
        return;
    }
    self.categoryName = newName; // valid (or an accepted no-op) at this point — ApolloSavedCategoryRename already returned early otherwise

    ApolloSavedCategorySetAppearance(self.categoryName, self.selectedColor, self.selectedSymbol);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)removeTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Remove Custom Appearance"
        message:[NSString stringWithFormat:@"“%@” will go back to the default look.", self.categoryName]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        ApolloSavedCategoryRemoveAppearance(self.categoryName);
        self.selectedColor = nil;
        self.selectedSymbol = nil;
        [self refreshPreview];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    self.selectedColor = viewController.selectedColor;
    [self refreshPreview];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    self.selectedColor = viewController.selectedColor;
    [self refreshPreview];
}

@end
