#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

// Push categories/actions; ids match the payloads the facebook skill sends through location-server /push.
extern NSString *const MarketplaceCategoryReply;    // FB_REPLY: Reply (text input)
extern NSString *const MarketplaceCategoryApprove;  // FB_APPROVE: Approve (sends data.suggested) + Reply
extern NSString *const MarketplaceActionReply;
extern NSString *const MarketplaceActionApprove;

/// Durable on-disk queue of Marketplace replies. A reply is written here (with
/// a client-minted opId, which the server dedupes on) before any network
/// attempt, and retried on launch/foreground until the server answers. A 4xx/5xx
/// marks the item rejected: it stays on disk for inspection but is never retried.
@interface MarketplaceOutbox : NSObject

/// Both categories the app registers with the notification center.
+ (NSSet<UNNotificationCategory *> *)notificationCategories;

/// Whether a default tap on a push of this category opens that question's thread.
+ (BOOL)categoryOpensThread:(NSString *)categoryId;

- (instancetype)initWithFileURL:(NSURL *)fileURL;

/// The JSON body POST /reply takes.
+ (NSDictionary *)replyBodyForListing:(NSString *)listing buyer:(NSString *)buyer text:(NSString *)text opId:(NSString *)opId;

/// A Bearer-authed JSON POST of `body` to `path` under `baseURL`.
+ (NSMutableURLRequest *)requestWithBaseURL:(NSURL *)baseURL path:(NSString *)path token:(NSString *)token body:(NSDictionary *)body;

/// Persists a reply and returns the stored item {id, listing, buyer, text, status}. nil + *error on write failure.
- (NSDictionary *)enqueueReplyForListing:(NSString *)listing buyer:(NSString *)buyer text:(NSString *)text error:(NSError **)error;

/// Items still to be sent (status "pending"), oldest first.
- (NSArray<NSDictionary *> *)pendingItems;
- (NSArray<NSDictionary *> *)allItems;
- (NSDictionary *)itemWithID:(NSString *)itemID;

- (void)removeItemWithID:(NSString *)itemID;
- (void)markRejectedItemWithID:(NSString *)itemID error:(NSString *)message;

/// Sends every pending item, in order. Stops at the first network failure (item
/// stays pending). `rejected` is called once per item the server refused.
/// `completion` runs on the main queue. Overlapping calls coalesce.
- (void)flushWithBaseURL:(NSURL *)baseURL
                   token:(NSString *)token
                 session:(NSURLSession *)session
                rejected:(void (^)(NSDictionary *item))rejected
              completion:(void (^)(void))completion;

@end
