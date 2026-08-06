#import "ApolloSavedCategoryStore.h"
#import "ApolloSavedCategoryAppearance.h"

static NSString *const kSavedCategoryStoreGroupSuiteName = @"group.com.christianselig.apollo";
static NSString *const kSavedCategoryStoreDatabaseKey = @"SavedItemsCategoriesDatabase";
static NSString *const kSavedCategoryStoreDuplicateError = @"A saved category already exists with that name, please choose a unique name.";

#pragma mark - Raw JSON read/write

static NSMutableDictionary *ApolloSavedCategoryReadDatabase(void) {
    NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kSavedCategoryStoreGroupSuiteName];
    NSData *data = [groupDefaults dataForKey:kSavedCategoryStoreDatabaseKey];
    if (!data) return nil;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return nil;

    return [json mutableCopy];
}

static void ApolloSavedCategoryWriteDatabase(NSDictionary *database) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:database options:0 error:&error];
    if (error || !data) return;

    NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kSavedCategoryStoreGroupSuiteName];
    [groupDefaults setObject:data forKey:kSavedCategoryStoreDatabaseKey];
    [groupDefaults synchronize];
}

#pragma mark - Public API

NSArray<NSString *> *ApolloSavedCategoryNames(void) {
    NSDictionary *db = ApolloSavedCategoryReadDatabase();
    NSDictionary *categories = db[@"categories"];
    if (![categories isKindOfClass:[NSDictionary class]]) return @[];
    return [categories.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

BOOL ApolloSavedCategoryNameIsValid(NSString *name) {
    if (!name) return NO;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return trimmed.length >= 3;
}

BOOL ApolloSavedCategoryAdd(NSString *name, NSString **outError) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!ApolloSavedCategoryNameIsValid(trimmed)) {
        if (outError) *outError = @"Category names need at least 3 characters.";
        return NO;
    }

    NSMutableDictionary *db = ApolloSavedCategoryReadDatabase();
    if (!db) db = [@{@"categories": [NSMutableDictionary dictionary]} mutableCopy];
    NSMutableDictionary *categories = db[@"categories"];
    if (!categories) {
        categories = [NSMutableDictionary dictionary];
        db[@"categories"] = categories;
    }

    for (NSString *existing in categories.allKeys) {
        if ([existing caseInsensitiveCompare:trimmed] == NSOrderedSame) {
            if (outError) *outError = kSavedCategoryStoreDuplicateError;
            return NO;
        }
    }

    categories[trimmed] = @[];
    ApolloSavedCategoryWriteDatabase(db);
    return YES;
}

BOOL ApolloSavedCategoryRename(NSString *oldName, NSString *newName, NSString **outError) {
    NSString *trimmed = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([trimmed isEqualToString:oldName]) return YES; // no-op, not an error

    if (!ApolloSavedCategoryNameIsValid(trimmed)) {
        if (outError) *outError = @"Category names need at least 3 characters.";
        return NO;
    }

    NSMutableDictionary *db = ApolloSavedCategoryReadDatabase();
    NSMutableDictionary *categories = db[@"categories"];
    if (!categories || !categories[oldName]) {
        if (outError) *outError = @"This category no longer exists.";
        return NO;
    }

    for (NSString *existing in categories.allKeys) {
        if ([existing caseInsensitiveCompare:oldName] == NSOrderedSame) continue;
        if ([existing caseInsensitiveCompare:trimmed] == NSOrderedSame) {
            if (outError) *outError = kSavedCategoryStoreDuplicateError;
            return NO;
        }
    }

    id items = categories[oldName];
    [categories removeObjectForKey:oldName];
    categories[trimmed] = items ?: @[];
    ApolloSavedCategoryWriteDatabase(db);
    ApolloSavedCategoryRenameAppearance(oldName, trimmed);
    return YES;
}

void ApolloSavedCategoryDelete(NSString *name) {
    NSMutableDictionary *db = ApolloSavedCategoryReadDatabase();
    NSMutableDictionary *categories = db[@"categories"];
    if (!categories) return;

    [categories removeObjectForKey:name];
    ApolloSavedCategoryWriteDatabase(db);
    ApolloSavedCategoryRemoveAppearance(name);
}
