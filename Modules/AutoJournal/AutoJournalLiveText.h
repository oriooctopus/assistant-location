#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure helpers for the Journal recorder's live transcript preview (never saved).
@interface AutoJournalLiveText : NSObject

// Committed text (earlier recognition tasks) followed by the current task's partial, single-space joined.
+ (NSString *)joinCommitted:(NSString *)committed partial:(NSString *)partial;

// The last `maxCharacters` of `text`, cut at a word boundary, with a leading ellipsis when the head was dropped.
// Text that already fits comes back unchanged.
+ (NSString *)tailOfText:(NSString *)text maxCharacters:(NSUInteger)maxCharacters;

@end

// Drops responses that belong to an older request: begin() on every send, isCurrent: on every reply.
@interface AutoJournalStaleGuard : NSObject
- (NSUInteger)begin;
- (BOOL)isCurrent:(NSUInteger)token;
- (void)invalidate; // every outstanding token becomes stale
@end

NS_ASSUME_NONNULL_END
