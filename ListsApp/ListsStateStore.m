#import "ListsStateStore.h"

#import <Security/Security.h>

#import "Lists-Swift.h"

static NSString *const kListsStateFile = @"state.json";

// The widget reads one generic-password item. Service, account and access group must equal the
// constants in ListsWidget/ListsWidget.swift (ListsConfigTests pins this). The access group is the
// Team-ID-prefixed string, not the `$(AppIdentifierPrefix)` macro used in the .entitlements file:
// SecItem calls need the resolved value at runtime (copied from QuotesStore.m, single-team setup).
// The ad-hoc profile for these bundle ids allows `J66WVM2DTX.*`, so no portal step is needed.
static NSString *const kListsKeychainService = @"com.oliverullman.lists";
static NSString *const kListsKeychainAccount = @"widget";
static NSString *const kListsKeychainAccessGroup = @"J66WVM2DTX.com.oliverullman.lists";

static NSString *const kListsErrorDomain = @"ListsStateStore";

static NSError *ListsError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kListsErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ListsStateStore

// ---- full state: Application Support/state.json ----

// The app's own Application Support directory (created on demand; it does not exist on first launch).
// Nothing shared with the widget, so no entitlement is involved.
- (NSURL *)stateURLError:(NSError **)error {
    NSURL *dir = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                             appropriateForURL:nil create:YES error:error];
    if (!dir) return nil;
    return [dir URLByAppendingPathComponent:kListsStateFile];
}

- (NSDictionary *)loadStateError:(NSError **)error {
    NSURL *url = [self stateURLError:error];
    if (!url) return nil;
    // First launch has no file; that is the only "empty" case. Every other failure below sets *error.
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!parsed) return nil;
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (error) *error = ListsError(2, [NSString stringWithFormat:@"state.json holds a %@, not an object", [parsed class]]);
        return nil;
    }
    return parsed;
}

// ---- widget snapshot ----

// Returns the dictionaries of `state[key]` that are not deleted; an error when the key is not an
// array of objects (the page and the app disagree about the schema, which must be loud).
static NSArray<NSDictionary *> *LiveRecords(NSDictionary *state, NSString *key, NSError **error) {
    id records = state[key];
    if (![records isKindOfClass:NSArray.class]) {
        if (error) *error = ListsError(3, [NSString stringWithFormat:@"state.%@ is a %@, not an array", key, [records class]]);
        return nil;
    }
    NSMutableArray *live = [NSMutableArray array];
    for (id record in records) {
        if (![record isKindOfClass:NSDictionary.class]) {
            if (error) *error = ListsError(3, [NSString stringWithFormat:@"state.%@ holds a %@, not an object", key, [record class]]);
            return nil;
        }
        if (![record[@"deleted"] boolValue]) [live addObject:record];
    }
    return live;
}

// Why trimmed: the keychain item is read by the widget on every timeline reload and item size is
// limited in practice, while the full state carries every item's `history`. The widget shows only
// unchecked live items, so everything else is dropped here.
+ (NSDictionary *)widgetSnapshotFromState:(NSDictionary *)state error:(NSError **)error {
    id version = state[@"v"];
    if (![version isKindOfClass:NSNumber.class]) {
        if (error) *error = ListsError(3, [NSString stringWithFormat:@"state.v is a %@, not a number", [version class]]);
        return nil;
    }
    NSArray *lists = LiveRecords(state, @"lists", error);
    if (!lists) return nil;
    NSArray *categories = LiveRecords(state, @"categories", error);
    if (!categories) return nil;
    NSArray *items = LiveRecords(state, @"items", error);
    if (!items) return nil;

    // `[dict[key] ?: NSNull.null]` keeps a missing optional key as an explicit null in the output, so
    // the widget's decoder sees the same shape whether or not the page set it.
    NSMutableArray *trimmed = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if ([item[@"checked"] boolValue]) continue;
        [trimmed addObject:@{
            @"id": item[@"id"] ?: NSNull.null,
            @"listId": item[@"listId"] ?: NSNull.null,
            @"name": item[@"name"] ?: NSNull.null,
            @"note": item[@"note"] ?: NSNull.null,
            @"categoryId": item[@"categoryId"] ?: NSNull.null,
            @"createdAt": item[@"createdAt"] ?: NSNull.null,
        }];
    }
    return @{
        @"v": version,
        @"widgetListId": state[@"widgetListId"] ?: NSNull.null,
        @"lists": lists,
        @"categories": categories,
        @"items": trimmed,
    };
}

// ---- keychain ----

// Inserts or updates the one generic-password item. Mirrors QuotesStore.m -saveData:error: except
// that a failure is always returned as an NSError (no exceptions), including errSecMissingEntitlement,
// so the page's saveState call sees it. Does NOT hide errSecMissingEntitlement as "nothing to do":
// a signed build always has the entitlement, so seeing it means the build is wrong.
- (BOOL)writeKeychain:(NSData *)payload error:(NSError **)error {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kListsKeychainService,
        (__bridge id)kSecAttrAccount: kListsKeychainAccount,
        (__bridge id)kSecAttrAccessGroup: kListsKeychainAccessGroup,
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: payload});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *insert = [query mutableCopy];
        insert[(__bridge id)kSecValueData] = payload;
        // AfterFirstUnlock, not WhenUnlocked: the widget extension must read this while the phone
        // is locked (same attribute QuotesStore.m uses). Only applied on insert, as there.
        insert[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    }
    if (status != errSecSuccess) {
        if (error) *error = ListsError(4, [NSString stringWithFormat:@"keychain write for the widget failed (OSStatus %d, group %@)", (int)status, kListsKeychainAccessGroup]);
        return NO;
    }
    return YES;
}

- (BOOL)saveState:(NSDictionary *)state error:(NSError **)error {
    NSURL *url = [self stateURLError:error];
    if (!url) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:error];
    if (!data) return NO;
    NSDictionary *snapshot = [ListsStateStore widgetSnapshotFromState:state error:error];
    if (!snapshot) return NO;
    NSData *snapshotData = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:error];
    if (!snapshotData) return NO;

    // The file first: it is the source of truth the page reloads from, so a keychain failure below
    // must not lose the user's edit. The failure is still reported, because the widget is then stale.
    if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
    if (![self writeKeychain:snapshotData error:error]) return NO;
    [GLListsWidgetReload reloadAllTimelines];
    return YES;
}

@end
