// ListenPlayer: the native audio engine behind the Listen tab. Implements the
// step loop, Now Playing and remote commands from PROTOCOL.md. The web view
// bridge, the pocket overlay and the voice listener all drive playback through
// exactly these methods.
//
// Every mutating method returns nil on success or a human-readable error
// string (never throws, never swallows); the bridge forwards it as the reply
// error, other callers surface it as an `error` event.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ListenPlayer : NSObject

/// Main-queue callback on every state change and at 4 Hz while playing.
@property (nonatomic, copy, nullable) void (^stateChanged)(void);
/// Main-queue callback for asynchronous failures (audio session, item failed).
@property (nonatomic, copy, nullable) void (^errorReported)(NSString *message);
/// Lock-screen / AirPods nextTrack. Return YES if handled (e.g. voice), NO for
/// the default (go to the next section).
@property (nonatomic, copy, nullable) BOOL (^nextTrackOverride)(void);

/// YES while the loop is running or a one-off replay clip is sounding.
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL hasItem;
@property (nonatomic, readonly) NSInteger currentIdx;
@property (nonatomic, readonly) NSInteger sectionCount;
@property (nonatomic, readonly, copy) NSDictionary *settings;

- (nullable NSString *)loadItemId:(NSString *)itemId
                            title:(NSString *)title
                         sections:(NSArray<NSDictionary *> *)sections
                         settings:(NSDictionary *)settings
                         startIdx:(NSInteger)startIdx;
- (nullable NSString *)setSettings:(NSDictionary *)settings;
- (nullable NSString *)play;
- (nullable NSString *)pause;
- (nullable NSString *)toggle;
- (nullable NSString *)next;
- (nullable NSString *)prev;
- (nullable NSString *)gotoIdx:(NSInteger)idx;
/// kind: original | clear | translation | vocab.
- (nullable NSString *)replay:(NSString *)kind;
/// Rewind: plays `steps` (kinds, in order; vocab skipped when the section has none) for the current section, `original` clips `slow` percent (0...50) slower than settings.rate, then resumes the loop.
- (nullable NSString *)rewindSteps:(NSArray<NSString *> *)steps slow:(NSInteger)slow;
/// Runs settings.rewinds[index] (the default preset when settings has none).
- (nullable NSString *)rewindPreset:(NSInteger)index;
/// Same, with `after`: @"resume" (continue the interrupted step) or @"advance" (count the section as finished once the clips end; stays paused if it was paused; with loop on, returns to looping). Any other value is an error.
- (nullable NSString *)rewindSteps:(NSArray<NSString *> *)steps slow:(NSInteger)slow after:(NSString *)after;
/// Session-only loop: while on, the current section plays only its `original` clip (at settings.rate) repeatedly, never advancing. On while playing restarts the original; off while playing lets the clip in flight finish, then playback moves on. Reset by load.
/// With rangeStart/rangeEnd (both or neither; absolute episode seconds, clamped to the current section) only that slice of the original repeats; calling again while on with a different or no range applies it (restarting the clip if playing). The range is cleared by loop off, load and any section change. A range with on:NO, or one outside the section, is an error.
- (nullable NSString *)setLoop:(BOOL)on rangeStart:(nullable NSNumber *)rangeStart rangeEnd:(nullable NSNumber *)rangeEnd;
/// Replays `original` slowed by settings.pocketReplaySlowdown percent (pocket two-finger tap).
- (nullable NSString *)replayOriginalSlowed;
/// Adds delta to settings.rate, clamped to 0.5...1.5.
- (nullable NSString *)adjustRateBy:(double)delta;

/// The State object from PROTOCOL.md minus the keys the view controller owns
/// (pocket, listening).
- (NSDictionary *)stateDictionary;

/// Validates a Settings object per PROTOCOL.md. Returns an error string or nil.
+ (nullable NSString *)validateSettings:(NSDictionary *)settings;

@end

NS_ASSUME_NONNULL_END
