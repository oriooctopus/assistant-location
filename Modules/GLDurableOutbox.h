// GLDurableOutbox -- a disk-backed queue of HTTP POSTs to the box. An item is
// written (manifest + body file) BEFORE any network attempt, replayed oldest
// first until the box answers, and only deleted once it did.
//
// Policy (see .claude/rules/offline-writes.md):
//   - transport error (offline, timeout, refused): item stays, retried on the
//     next flush (launch, foreground, enqueue, and a timer while items wait);
//   - HTTP 2xx: item done (deleted, or "completed" with its response body kept
//     when keepResult is set, until the consumer calls -removeItemID:);
//   - any other HTTP status (4xx/5xx), unless listed in acceptedStatuses: item
//     is marked "rejected", never retried automatically, and
//     GLDurableOutboxDidRejectNotification is posted so the UI can say so.
//     Exception: an item enqueued with retryTransient treats 5xx, 429 and 408
//     like a transport error (the box is struggling, not refusing): it stays
//     pending and is retried, and only other statuses reject it.
//
// Foundation-only so SharedTests can compile it; the production singleton
// lives in GLDurableOutboxShared.m (needs BakedConfig, app target only).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue; userInfo[@"item"] is the item dictionary.
extern NSString *const GLDurableOutboxDidRejectNotification;
/// A manifest could not be read and was moved aside (userInfo[@"id"]); its body is kept. Posted on main.
extern NSString *const GLDurableOutboxDidQuarantineNotification;

extern NSString *const GLDurableOutboxStatePending;
extern NSString *const GLDurableOutboxStateRejected;
extern NSString *const GLDurableOutboxStateCompleted;

@interface GLDurableOutbox : NSObject

/// Seconds between automatic retries while items are pending. Default 20.
@property (nonatomic) NSTimeInterval retryInterval;

/// `urlBuilder` turns an item's path ("/drop") into the full URL; `token` is
/// sent as a Bearer header at send time and never written to disk.
- (instancetype)initWithDirectory:(NSURL *)directory
                       urlBuilder:(NSURL *(^)(NSString *path))urlBuilder
                            token:(NSString *)token
             sessionConfiguration:(nullable NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Persists the item synchronously and returns its id, or nil with `error`
/// when the disk write failed (the caller must then NOT clear its UI).
/// Does not send: call -flushWithCompletion: afterwards.
- (nullable NSString *)enqueueKind:(NSString *)kind
                              path:(NSString *)path
                           headers:(NSDictionary<NSString *, NSString *> *)headers
                              body:(NSData *)body
                              meta:(nullable NSDictionary *)meta
                        keepResult:(BOOL)keepResult
                  acceptedStatuses:(nullable NSArray<NSNumber *> *)acceptedStatuses
                             error:(NSError **)error;
/// As above, with `retryTransient` (see the policy at the top of this file).
- (nullable NSString *)enqueueKind:(NSString *)kind
                              path:(NSString *)path
                           headers:(NSDictionary<NSString *, NSString *> *)headers
                              body:(NSData *)body
                              meta:(nullable NSDictionary *)meta
                        keepResult:(BOOL)keepResult
                  acceptedStatuses:(nullable NSArray<NSNumber *> *)acceptedStatuses
                    retryTransient:(BOOL)retryTransient
                             error:(NSError **)error;

/// Sends every pending item oldest-first, stopping at the first transport
/// error. `completion` (main queue) runs when the pass is over.
- (void)flushWithCompletion:(nullable void (^)(void))completion;

/// Production wiring: Application Support/DurableOutbox.
+ (NSURL *)defaultDirectory;

/// Flush now, and again every time the app becomes active. (Failed items also retry on a timer, see retryInterval.)
- (void)startDraining;

/// Ids of manifests that were unreadable and quarantined (their bodies are still on disk).
- (NSArray<NSString *> *)quarantinedItemIDs;

/// All items on disk, oldest first. Keys: id, kind, path, headers, state,
/// keepResult, acceptedStatuses, retryTransient, meta, createdAt, attempts, lastError,
/// rejectedStatus, resultStatus.
- (NSArray<NSDictionary *> *)items;
- (nullable NSDictionary *)itemWithID:(NSString *)itemID;
/// The request body as queued (still on disk until -removeItemID:).
- (nullable NSData *)bodyDataForItemID:(NSString *)itemID;
/// Response body of a completed keepResult item.
- (nullable NSData *)resultDataForItemID:(NSString *)itemID;
/// Deletes an item and its files (acknowledge a result, or discard a rejection).
- (void)removeItemID:(NSString *)itemID;
/// Puts a rejected item back to pending. Call -flushWithCompletion: after.
- (void)retryRejectedItemID:(NSString *)itemID;

@end

NS_ASSUME_NONNULL_END
