#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Pure helpers for the Journal recorder's live transcript preview (never saved).
@interface AutoJournalLiveText : NSObject

// Committed text (earlier recognition tasks) followed by the current task's partial, single-space joined.
+ (NSString *)joinCommitted:(NSString *)committed partial:(NSString *)partial;

// The last `maxCharacters` of `text`, cut at a word boundary, with a leading ellipsis when the head was dropped.
// Text that already fits comes back unchanged.
+ (NSString *)tailOfText:(NSString *)text maxCharacters:(NSUInteger)maxCharacters;

// dB (AVAudioRecorder averagePowerForChannel: range, 0 = full scale, negative below) to a 0..1 bar height.
// Linear in dB between `floorDb` (and anything quieter) = 0 and 0 dB (and anything louder) = 1. Linear-in-dB is
// what a level meter shows, and it keeps quiet-room noise (about -50 dB) from drawing as a visible bar.
+ (CGFloat)levelForDecibels:(float)decibels floorDb:(float)floorDb;

// "-40, -20,-5" -> @[-40, -20, -5]. Parses the UITEST_JOURNAL_LEVELS hook; blank/invalid entries are dropped.
+ (NSArray<NSNumber *> *)decibelListFromString:(NSString *)csv;

@end

// Fixed-size history of recent levels for the scrolling meter: push appends at the right, the oldest falls off the
// left, and `levels` is always exactly `capacity` long (missing history reads as 0 so the bars start flat).
@interface AutoJournalLevelBuffer : NSObject
- (instancetype)initWithCapacity:(NSUInteger)capacity;
@property(nonatomic, readonly) NSUInteger capacity;
- (void)push:(CGFloat)level;
- (void)clear;
@property(nonatomic, readonly) NSArray<NSNumber *> *levels; // oldest first, newest last
@end

// Drops responses that belong to an older request: begin() on every send, isCurrent: on every reply.
@interface AutoJournalStaleGuard : NSObject
- (NSUInteger)begin;
- (BOOL)isCurrent:(NSUInteger)token;
- (void)invalidate; // every outstanding token becomes stale
@end

NS_ASSUME_NONNULL_END
