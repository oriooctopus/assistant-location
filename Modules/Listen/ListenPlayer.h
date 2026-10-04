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
/// Plays `kind` once, `slowdown` (0...1) slower than settings.rate when it is `original`, then `then` (nil for none), then resumes the loop.
- (nullable NSString *)replay:(NSString *)kind slowdown:(double)slowdown then:(nullable NSString *)then;
/// Pocket two-finger tap: replay `original` slowed by settings.pocketReplaySlowdown percent.
- (nullable NSString *)replayOriginalSlowed;
/// Pocket two-finger double tap: replay the English clip, then the original at normal rate.
- (nullable NSString *)replayTranslationThenOriginal;
/// Adds delta to settings.rate, clamped to 0.5...1.5.
- (nullable NSString *)adjustRateBy:(double)delta;

/// The State object from PROTOCOL.md minus the keys the view controller owns
/// (pocket, listening).
- (NSDictionary *)stateDictionary;

/// Validates a Settings object per PROTOCOL.md. Returns an error string or nil.
+ (nullable NSString *)validateSettings:(NSDictionary *)settings;

@end

NS_ASSUME_NONNULL_END
