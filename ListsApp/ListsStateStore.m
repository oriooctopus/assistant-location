#import "ListsStateStore.h"

#import "Lists-Swift.h"

// Must equal the group in Lists.entitlements, ListsWidget.entitlements and ListsWidget.swift.
static NSString *const kListsAppGroup = @"group.com.oliverullman.lists";
static NSString *const kListsStateFile = @"state.json";

@implementation ListsStateStore

// A nil container means the App Group entitlement is missing from the signed build (the profile
// does not carry the group). That is a signing bug, reported as an error naming the group.
- (NSURL *)stateURLError:(NSError **)error {
    NSURL *container = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:kListsAppGroup];
    if (!container) {
        if (error) {
            *error = [NSError errorWithDomain:@"ListsStateStore" code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"no App Group container for %@ (entitlement missing from the signed build?)", kListsAppGroup]}];
        }
        return nil;
    }
    return [container URLByAppendingPathComponent:kListsStateFile];
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
        if (error) *error = [NSError errorWithDomain:@"ListsStateStore" code:2 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"state.json holds a %@, not an object", [parsed class]]}];
        return nil;
    }
    return parsed;
}

- (BOOL)saveState:(NSDictionary *)state error:(NSError **)error {
    NSURL *url = [self stateURLError:error];
    if (!url) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:error];
    if (!data) return NO;
    if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
    [GLListsWidgetReload reloadAllTimelines];
    return YES;
}

@end
