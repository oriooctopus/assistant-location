// Per-clip named sections (start/end in seconds). Written to disk first, then
// queued in a GLDurableOutbox as a POST of the clip's whole section list to
// /clips/<id>/sections, so edits work offline and sync when the box is back.

#import <Foundation/Foundation.h>

@class GLDurableOutbox;

NS_ASSUME_NONNULL_BEGIN

@interface ClipsSectionsStore : NSObject

/// `outbox` is called when a write needs queueing; returning nil (no server in
/// this build) leaves the write local only.
- (instancetype)initWithDirectory:(NSURL *)directory outbox:(GLDurableOutbox *_Nullable (^)(void))outbox;

/// Sections for a clip, ordered by start. Each is {id, name, start (NSNumber), end (NSNumber)}.
- (NSArray<NSDictionary *> *)sectionsForClip:(NSString *)clipID;
- (NSDictionary *)addSectionToClip:(NSString *)clipID name:(NSString *)name start:(NSTimeInterval)start end:(NSTimeInterval)end;
/// Sets whichever of name / start / end are non-nil.
- (void)updateSection:(NSString *)sectionID inClip:(NSString *)clipID
                 name:(nullable NSString *)name start:(nullable NSNumber *)start end:(nullable NSNumber *)end;
- (void)deleteSection:(NSString *)sectionID inClip:(NSString *)clipID;
/// Takes the server's list, unless a local write for this clip is still queued.
- (void)adoptServerSections:(NSArray<NSDictionary *> *)sections forClip:(NSString *)clipID;
- (BOOL)hasUnsyncedWritesForClip:(NSString *)clipID;

/// The section a `?section=` reference names: an exact id first, otherwise a
/// 1-based position in the list. nil when it names neither.
+ (nullable NSDictionary *)sectionForReference:(NSString *)reference inSections:(NSArray<NSDictionary *> *)sections;

@end

NS_ASSUME_NONNULL_END
