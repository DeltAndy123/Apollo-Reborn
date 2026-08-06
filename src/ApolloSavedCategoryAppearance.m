#import "ApolloSavedCategoryAppearance.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

// Mirrors settings/SavedCategoriesViewController.m's own constant — kept as a
// separate static here rather than shared, matching how ApolloBackupRestore.m
// and that file each already define their own copy.
static NSString *const kSavedCategoryGroupSuiteName = @"group.com.christianselig.apollo";
static NSString *const kSavedCategoriesDatabaseKey = @"SavedItemsCategoriesDatabase";

#pragma mark - ApolloSavedCategoryAppearance model

@implementation ApolloSavedCategoryAppearance
@end

#pragma mark - Curated symbol list

NSArray<NSString *> *ApolloSavedCategorySymbolChoices(void) {
    static NSArray<NSString *> *choices;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        choices = @[
            @"star.fill", @"bookmark.fill", @"tag.fill", @"flame.fill",
            @"heart.fill", @"pin.fill", @"folder.fill", @"tray.fill",
            @"book.fill", @"graduationcap.fill", @"lightbulb.fill", @"wrench.fill",
            @"gamecontroller.fill", @"film.fill", @"music.note", @"camera.fill",
            @"cart.fill", @"gift.fill", @"airplane", @"car.fill",
            @"house.fill", @"leaf.fill", @"pawprint.fill", @"fork.knife",
            @"cup.and.saucer.fill", @"dumbbell.fill", @"paintbrush.fill", @"hammer.fill",
            @"newspaper.fill", @"quote.bubble.fill", @"exclamationmark.circle.fill", @"questionmark.circle.fill",
            @"checkmark.circle.fill", @"clock.fill", @"calendar", @"bell.fill",
            @"flag.fill", @"bolt.fill", @"moon.fill", @"sun.max.fill",
        ];
    });
    return choices;
}

#pragma mark - Appearance side-store (standardUserDefaults)

static NSDictionary<NSString *, NSDictionary *> *ApolloSavedCategoryAppearanceStore(void) {
    NSDictionary *store = [[NSUserDefaults standardUserDefaults] dictionaryForKey:UDKeySavedCategoryAppearance];
    return [store isKindOfClass:[NSDictionary class]] ? store : @{};
}

static void ApolloSavedCategoryWriteAppearanceStore(NSDictionary<NSString *, NSDictionary *> *store) {
    [[NSUserDefaults standardUserDefaults] setObject:store forKey:UDKeySavedCategoryAppearance];
}

ApolloSavedCategoryAppearance *ApolloSavedCategoryAppearanceFor(NSString *name) {
    if (name.length == 0) return nil;
    NSDictionary *entry = ApolloSavedCategoryAppearanceStore()[name];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;

    NSString *hex = entry[@"color"];
    NSString *symbol = entry[@"symbol"];
    UIColor *color = [hex isKindOfClass:[NSString class]] ? ApolloColorFromHexString(hex) : nil;
    if (![symbol isKindOfClass:[NSString class]] || symbol.length == 0) symbol = nil;
    if (!color && !symbol) return nil;

    ApolloSavedCategoryAppearance *appearance = [ApolloSavedCategoryAppearance new];
    appearance.color = color;
    appearance.symbolName = symbol;
    return appearance;
}

void ApolloSavedCategorySetAppearance(NSString *name, UIColor *color, NSString *symbolName) {
    if (name.length == 0) return;
    NSMutableDictionary *store = [ApolloSavedCategoryAppearanceStore() mutableCopy];

    NSString *hex = color ? ApolloHexStringFromColor(color) : nil;
    if (!hex && symbolName.length == 0) {
        [store removeObjectForKey:name];
    } else {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        if (hex) entry[@"color"] = hex;
        if (symbolName.length > 0) entry[@"symbol"] = symbolName;
        store[name] = entry;
    }
    ApolloSavedCategoryWriteAppearanceStore(store);
    ApolloLog(@"[SavedCategoryAppearance] set %@ -> color=%@ symbol=%@", name, hex, symbolName);
}

void ApolloSavedCategoryRenameAppearance(NSString *oldName, NSString *newName) {
    if (oldName.length == 0 || newName.length == 0 || [oldName isEqualToString:newName]) return;
    NSMutableDictionary *store = [ApolloSavedCategoryAppearanceStore() mutableCopy];
    NSDictionary *entry = store[oldName];
    if (!entry) return;
    [store removeObjectForKey:oldName];
    store[newName] = entry;
    ApolloSavedCategoryWriteAppearanceStore(store);
}

void ApolloSavedCategoryRemoveAppearance(NSString *name) {
    if (name.length == 0) return;
    NSMutableDictionary *store = [ApolloSavedCategoryAppearanceStore() mutableCopy];
    if (!store[name]) return;
    [store removeObjectForKey:name];
    ApolloSavedCategoryWriteAppearanceStore(store);
}

#pragma mark - Reverse index (item fullname -> category name)

// Apollo keeps no in-memory copy of SavedItemsCategoriesDatabase — its getter
// re-reads + re-decodes the group-suite JSON on every access, and writes go
// through synchronously (Hopper: sub_1002590c4 / sub_100259e8c). Reading the
// same JSON here directly is therefore never stale; we only cache to avoid
// paying JSON decode + index-build cost on every cell render.
static NSDictionary<NSString *, NSString *> *ApolloSavedCategoryReverseIndex(void) {
    static NSDictionary<NSString *, NSString *> *cached;
    static BOOL dirty = YES;
    static dispatch_once_t setupOnce;

    dispatch_once(&setupOnce, ^{
        void (^invalidate)(NSNotification *) = ^(NSNotification *note) {
            dirty = YES;
        };
        // Apollo's own native category UI (and this tweak's settings screen)
        // both write through NSUserDefaults, which posts this notification —
        // covers writes from either side without a bespoke change channel.
        [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:invalidate];
        // Apollo mirrors SavedItemsCategoriesDatabase to iCloud KVS (Hopper:
        // sub_100259e8c writes both); a cross-device sync lands here, not
        // through the local NSUserDefaults notification above.
        [[NSNotificationCenter defaultCenter] addObserverForName:NSUbiquitousKeyValueStoreDidChangeExternallyNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:invalidate];
    });

    if (!dirty && cached) return cached;

    NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kSavedCategoryGroupSuiteName];
    NSData *data = [groupDefaults dataForKey:kSavedCategoriesDatabaseKey];
    NSDictionary *categories = nil;
    if (data) {
        NSError *error = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [json isKindOfClass:[NSDictionary class]]) {
            id maybeCategories = ((NSDictionary *)json)[@"categories"];
            if ([maybeCategories isKindOfClass:[NSDictionary class]]) categories = maybeCategories;
        }
    }

    NSMutableDictionary<NSString *, NSString *> *index = [NSMutableDictionary dictionary];
    if (categories) {
        // Alphabetically-first category wins for an item saved to more than
        // one — deterministic regardless of NSDictionary iteration order.
        NSArray<NSString *> *namesAscending = [categories.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *name in namesAscending.reverseObjectEnumerator) {
            NSArray *itemIDs = categories[name];
            if (![itemIDs isKindOfClass:[NSArray class]]) continue;
            for (NSString *itemID in itemIDs) {
                if ([itemID isKindOfClass:[NSString class]]) index[itemID] = name;
            }
        }
    }

    cached = [index copy];
    dirty = NO;
    return cached;
}

NSString *ApolloSavedCategoryForItemID(NSString *fullName) {
    if (fullName.length == 0) return nil;
    return ApolloSavedCategoryReverseIndex()[fullName];
}

#pragma mark - Stock color

UIColor *ApolloSavedCategoryDefaultColor(UITraitCollection *traits) {
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    return ApolloColorFromHexString(dark ? @"00940F" : @"07BE00");
}

#pragma mark - Triangle indicator rendering

UIImage *ApolloSavedCategoryTriangleImage(UIImage *baseAsset, UIColor *color, NSString *symbolName, UITraitCollection *traits) {
    if (!baseAsset || !color || baseAsset.size.width <= 0.0 || baseAsset.size.height <= 0.0) return baseAsset;

    UIColor *resolved = [color resolvedColorWithTraitCollection:traits];

    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });

    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0.5;
        [resolved getWhite:&w alpha:&a];
        r = g = b = w;
    }
    NSString *key = [NSString stringWithFormat:@"%p|%.3f|%.3f|%.3f|%.3f|%@",
                      baseAsset, r, g, b, a, symbolName ?: @""];
    UIImage *cached = [cache objectForKey:key];
    if (cached) return cached;

    CGRect rect = CGRectMake(0.0, 0.0, baseAsset.size.width, baseAsset.size.height);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:baseAsset.size format:fmt];

    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // Fill the stock triangle's own silhouette with the category color
        // (source-in composite, same trick as ApolloProfileTintedSymbol in
        // ApolloUserAvatars.xm) — guarantees the shape/edges stay pixel-identical
        // to Apollo's asset.
        [baseAsset drawInRect:rect];
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeSourceIn);
        CGContextSetFillColorWithColor(ctx.CGContext, resolved.CGColor);
        CGContextFillRect(ctx.CGContext, rect);

        if (symbolName.length > 0) {
            // Contrast the glyph against whatever category color was chosen,
            // same rule the settings icon tiles use (ApolloSettingsForm.m).
            UIColor *glyphColor = ApolloColorIsLight(resolved) ? UIColor.blackColor : UIColor.whiteColor;
            CGFloat glyphPointSize = MIN(rect.size.width, rect.size.height) * 0.42;
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:glyphPointSize weight:UIImageSymbolWeightBold];
            UIImage *glyph = [[UIImage systemImageNamed:symbolName withConfiguration:cfg]
                               imageWithTintColor:glyphColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            if (glyph && glyph.size.width > 0 && glyph.size.height > 0) {
                CGContextSetBlendMode(ctx.CGContext, kCGBlendModeNormal);
                // The triangle's visual mass sits toward its bottom-right corner
                // (the right-angle corner), so bias the glyph the same way rather
                // than centering it in the full bounding box.
                CGSize gs = glyph.size;
                CGFloat scale = MIN(1.0, MIN((rect.size.width * 0.5) / gs.width, (rect.size.height * 0.5) / gs.height));
                gs = CGSizeMake(gs.width * scale, gs.height * scale);
                CGFloat originX = rect.size.width - gs.width - (rect.size.width * 0.09);
                CGFloat originY = rect.size.height - gs.height - (rect.size.height * 0.09);
                [glyph drawInRect:CGRectMake(originX, originY, gs.width, gs.height)];
            }
        }
    }];

    result = [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    [cache setObject:result forKey:key];
    return result;
}
