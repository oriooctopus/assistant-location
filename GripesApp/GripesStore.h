#import <Foundation/Foundation.h>

/// Source of truth for Gripes entries: one JSON file in Application Support, written before
/// anything else happens, so the app is fully usable offline. Every upsert also marks the entry
/// dirty in a second file (the durable outbox); a sync pushes dirty entries to the box and pulls
/// newer ones. Sync never blocks or fails the UI: a network error just leaves entries dirty.
@interface GripesStore : NSObject

- (instancetype)initWithDirectory:(NSURL *)directory;

- (NSArray<NSDictionary *> *)allEntries;
/// Insert or replace by id; an existing entry with a newer updatedAt wins. NO + *error on write failure.
- (BOOL)upsertEntry:(NSDictionary *)entry error:(NSError **)error;
/// There is deliberately no delete: the page's Undo upserts a tombstone (`deleted:true`, newer
/// updatedAt) which stays in local storage and syncs like any edit.
/// IDs still waiting to be pushed.
- (NSArray<NSString *> *)dirtyIDs;

/// Pushes dirty entries (POST /api/entries) then pulls newer ones (GET /api/entries?since=).
/// `completion(changed)` runs on the main queue; changed = the pull altered the local store.
/// Overlapping calls coalesce (the later one completes immediately with NO).
- (void)syncWithBaseURL:(NSURL *)baseURL
                  token:(NSString *)token
                session:(NSURLSession *)session
             completion:(void (^)(BOOL changed))completion;

/// Bearer-authed JSON request builder (body nil -> GET).
+ (NSMutableURLRequest *)requestWithURL:(NSURL *)url token:(NSString *)token body:(NSDictionary *)body;

@end
