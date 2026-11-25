#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Display-only live transcript shown while the mic records. Never saved: the AVAudioRecorder clip in CycleSpeech is the
/// source of truth (the box transcribes it), so a failure here only costs the on-screen words.
@protocol CycleLiveTranscribing <NSObject>
/// Whole transcript so far; fires on every change. Main queue.
@property (nonatomic, copy, nullable) void (^onText)(NSString *text);
/// Why live text stopped working. Main queue. Must never be surfaced as a recording failure.
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
/// Starts listening (requests speech authorization the first time). Call after the recorder is running.
- (void)start;
/// Stops listening and clears the text.
- (void)reset;
@end

/// Adapted from AutoJournalLiveTranscriber (Superapp's Journal): an AVAudioEngine input tap feeding SFSpeechRecognizer,
/// running next to the AVAudioRecorder. Self-contained so the Cycle target needs nothing from Modules/.
@interface CycleLiveTranscriber : NSObject <CycleLiveTranscribing>
@end

NS_ASSUME_NONNULL_END
