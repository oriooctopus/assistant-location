// Per-clip notes, each stamped with a playback time. Written to disk first,
// then queued in a GLDurableOutbox as a POST of the clip's whole note list to
// /clips/<id>/notes, so editing works offline and syncs when the box is back.

#import <Foundation/Foundation.h>

@class GLDurableOutbox;

NS_ASSUME_NONNULL_BEGIN

@interface ClipsNotesStore : NSObject

/// `outbox` is called when a write needs queueing; returning nil (no server in
/// this build) leaves the write local only.
- (instancetype)initWithDirectory:(NSURL *)directory outbox:(GLDurableOutbox *_Nullable (^)(void))outbox;

/// Notes for a clip, ordered by time. Each is {id, time (NSNumber), text}.
- (NSArray<NSDictionary *> *)notesForClip:(NSString *)clipID;
- (NSDictionary *)addNoteToClip:(NSString *)clipID time:(NSTimeInterval)time text:(NSString *)text;
- (void)setText:(NSString *)text ofNote:(NSString *)noteID inClip:(NSString *)clipID;
- (void)deleteNote:(NSString *)noteID inClip:(NSString *)clipID;
/// Takes the server's list, unless a local write for this clip is still queued.
- (void)adoptServerNotes:(NSArray<NSDictionary *> *)notes forClip:(NSString *)clipID;
/// True while a queued write for this clip has not reached the server.
- (BOOL)hasUnsyncedWritesForClip:(NSString *)clipID;

@end

NS_ASSUME_NONNULL_END
