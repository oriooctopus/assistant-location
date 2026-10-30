// Practice takes recorded in the Clips player. The audio stays on the phone, so
// a take plays with no connection. Each new take is also queued in a
// GLDurableOutbox as a POST to /clips/<id>/align, and the box's answer (where in
// the song each moment of the take falls) is saved onto the take when it is back.

#import <Foundation/Foundation.h>

@class GLDurableOutbox;

NS_ASSUME_NONNULL_BEGIN

@interface ClipsTakesStore : NSObject

/// `outbox` is called when a take needs uploading; returning nil (no server in
/// this build) leaves the take unplaced but playable.
- (instancetype)initWithDirectory:(NSURL *)directory outbox:(GLDurableOutbox *_Nullable (^)(void))outbox;

/// Takes for a clip, newest first. Each is {id, created (epoch seconds), duration,
/// and once the box has answered, map: [[takeSeconds, songSeconds], ...]}.
- (NSArray<NSDictionary *> *)takesForClip:(NSString *)clipID;
/// Where a recorder should write a new take.
- (NSURL *)newRecordingURL;
- (NSURL *)fileURLForTake:(NSDictionary *)take;
/// Saves the finished file at `url` (from -newRecordingURL) as a take and queues its upload.
- (NSDictionary *)addTakeAtURL:(NSURL *)url toClip:(NSString *)clipID duration:(NSTimeInterval)duration;
- (void)deleteTake:(NSString *)takeID inClip:(NSString *)clipID;
/// Sends anything queued, saves every answer that has come back, then calls `completion` on main.
- (void)syncAlignmentsForClip:(NSString *)clipID completion:(void (^)(void))completion;

/// The song time at `takeTime`, or nil where the map has a gap (that part of the take is unplaced).
+ (nullable NSNumber *)songTimeForTakeTime:(NSTimeInterval)takeTime inMap:(nullable NSArray<NSArray<NSNumber *> *> *)map;
/// The moment in the take that best matches `songTime`, or nil when the take never played it.
+ (nullable NSNumber *)takeTimeForSongTime:(NSTimeInterval)songTime inMap:(nullable NSArray<NSArray<NSNumber *> *> *)map;

@end

NS_ASSUME_NONNULL_END
