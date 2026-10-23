// ListenSpeakTurn: one hands-free Listen & speak turn run natively, for when the page cannot show the stop (app not
// active, i.e. screen locked, or the pocket view is up). WKWebView JS is suspended on a locked screen, so the turn
// cannot live in the page; this class does all of it itself:
//   1. prompt   speak "repeat what you heard" / "summarize" (GET /api/speak/prompt.mp3, in the item's language)
//   2. recording record the answer (AAC .m4a, mono, metered), ending on silence or a cap
//   3. grading  POST the recording to /api/speak/grade (speak=1: the server also returns feedbackAudioUrl)
//   4. feedback play the spoken feedback
//   5. onFinished(afterIdx): the owner (ListenPlayer, via the view controller) continues playback at afterIdx + 1
// Every failure (denied mic, network, HTTP error such as "no speech was recognised", TTS) calls onError with the real
// reason and then onFinished, so playback always continues. Silence for kNoSpeechGiveUp seconds is not an error, it
// just gives up and continues.
//
// iOS constraint this design is built around: an app can only START audio capture in the background if its audio
// session is already active. The player never deactivates the session (see -[ListenPlayer parkAfterRun]); this class
// switches the live session to playAndRecord and the player switches it back to playback afterwards.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ListenSpeakTurn : NSObject

/// nil when idle, else prompt | recording | grading | feedback (State.speakTurn in PROTOCOL.md).
@property (nonatomic, readonly, copy, nullable) NSString *phase;

/// Main-queue callbacks.
@property (nonatomic, copy, nullable) void (^onPhaseChanged)(void);
/// The grade JSON from the server, as soon as it is back (before the feedback is spoken).
@property (nonatomic, copy, nullable) void (^onResult)(NSDictionary *result);
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
/// The turn is over (success, failure or give-up); `afterIdx` is the stop's section. phase is already nil.
@property (nonatomic, copy, nullable) void (^onFinished)(NSInteger afterIdx);

/// `base` is the Listen server root, e.g. https://host:9315/.
- (instancetype)initWithBaseURL:(NSURL *)base;

/// Starts a turn for `stop` ({afterIdx, kind repeat|summary, from, to}) of item `itemId`. Returns NO (and does nothing)
/// if a turn is already running.
- (BOOL)startWithItemId:(NSString *)itemId stop:(NSDictionary *)stop;

/// Pocket double-press while the feedback plays: cuts it off and records a fresh answer. Returns YES if it did; NO in
/// every other phase so the press keeps its usual meaning.
- (BOOL)retryFromFeedback;

/// Abandons a running turn without calling onError / onFinished (a new item was loaded).
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
