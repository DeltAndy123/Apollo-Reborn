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

    // Apollo's own SavedItemsCategoriesDatabase.save(newCategories:) writes the
    // group suite AND mirrors the same blob to iCloud key-value storage — that
    // mirror is what carries categories across a user's devices. Writing only
    // the local suite would make any change made here (rename, delete, and
    // especially an item's category assignment from the "..." menu) silently
    // fail to sync, while Apollo's own equivalent edits do sync. Same key, same
    // full read-modify-write blob shape Apollo writes, so the two paths stay
    // interchangeable rather than fighting over the record.
    [[NSUbiquitousKeyValueStore defaultStore] setData:data forKey:kSavedCategoryStoreDatabaseKey];

    // Membership just changed, so the item -> category index the saved-corner
    // indicator and the "..." menu row both read is now stale. The change
    // notifications would eventually cover this, but callers here need the
    // very next read to be correct.
    ApolloSavedCategoryInvalidateItemIndex();
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

void ApolloSavedCategorySetItemCategory(NSString *fullName, NSString *categoryName) {
    if (fullName.length == 0) return;

    NSMutableDictionary *db = ApolloSavedCategoryReadDatabase();
    NSMutableDictionary *categories = db[@"categories"];
    if (![categories isKindOfClass:[NSDictionary class]]) return;
    if (categoryName.length > 0 && !categories[categoryName]) return; // unknown category — don't invent one

    // Apollo's schema is category -> [itemID], so "which category is this in"
    // is expressed purely by membership. Strip the item from every category
    // first (that alone implements the Remove case, and keeps a move from
    // leaving the item in two places), then add it back to the target.
    BOOL changed = NO;
    for (NSString *name in categories.allKeys) {
        id items = categories[name];
        if (![items isKindOfClass:[NSArray class]]) continue;
        if (![(NSArray *)items containsObject:fullName]) continue;
        NSMutableArray *mutableItems = [(NSArray *)items mutableCopy];
        [mutableItems removeObject:fullName];
        categories[name] = mutableItems;
        changed = YES;
    }

    if (categoryName.length > 0) {
        id items = categories[categoryName];
        NSMutableArray *mutableItems = [items isKindOfClass:[NSArray class]] ? [(NSArray *)items mutableCopy] : [NSMutableArray array];
        [mutableItems addObject:fullName];
        categories[categoryName] = mutableItems;
        changed = YES;
    }

    if (!changed) return;
    ApolloSavedCategoryWriteDatabase(db);
}

void ApolloSavedCategoryDelete(NSString *name) {
    NSMutableDictionary *db = ApolloSavedCategoryReadDatabase();
    NSMutableDictionary *categories = db[@"categories"];
    if (!categories) return;

    [categories removeObjectForKey:name];
    ApolloSavedCategoryWriteDatabase(db);
    ApolloSavedCategoryRemoveAppearance(name);
}
