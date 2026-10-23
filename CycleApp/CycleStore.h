#import <Foundation/Foundation.h>

extern NSString *const CycleStoreErrorDomain;

/// Durable key/value store behind the bridge's store.* commands: one JSON dictionary file in
/// Application Support, rewritten atomically on every change. Application Support is part of the
/// device backup and survives app updates; nothing here is excluded from backup.
/// Main thread only (the bridge calls it from WKScriptMessageHandler callbacks).
@interface CycleStore : NSObject

/// Loads `<directory>/cycle-store.json`. A missing file is an empty store; an unreadable or
/// malformed one returns nil with *error set, so a bad file is never silently overwritten.
- (instancetype)initWithDirectory:(NSURL *)directory error:(NSError **)error;

- (NSString *)valueForKey:(NSString *)key;
/// A nil value deletes the key. NO + *error when the file could not be written (the in-memory
/// state is rolled back so memory and disk never disagree).
- (BOOL)setValue:(NSString *)value forKey:(NSString *)key error:(NSError **)error;
/// Keys starting with `prefix` (empty prefix = all keys), sorted.
- (NSArray<NSString *> *)keysWithPrefix:(NSString *)prefix;

@end
