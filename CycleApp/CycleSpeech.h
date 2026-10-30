#import <Foundation/Foundation.h>

/// Live speech-to-text for a page field (bridge `speech.start` / `speech.stop`): SFSpeechRecognizer fed by an
/// AVAudioEngine tap, partial transcripts streamed to `onText`. On-device whenever the recognizer supports it.
/// Nothing is recorded to disk or uploaded by us.
@interface CycleSpeech : NSObject

/// Main queue. The whole transcript so far; `final` = capture ended (the recognizer finished or hit a normal end).
@property (nonatomic, copy) void (^onText)(NSString *text, BOOL final);
/// Main queue. A short user-facing reason a running capture failed.
@property (nonatomic, copy) void (^onError)(NSString *message);

/// Asks for the speech and microphone permissions on first use, then starts capture. `done(nil)` once capturing,
/// else `done(@"Mic off")` when either permission is denied or `done(<short reason>)`. Main queue, exactly once.
- (void)startWithCompletion:(void (^)(NSString *error))done;
/// Stops capture and releases the microphone and the audio session. Safe when idle.
- (void)stop;

@end
