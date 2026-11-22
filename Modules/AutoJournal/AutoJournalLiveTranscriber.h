#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Live, on-screen-only transcript of the Journal recorder. Runs an AVAudioEngine input tap into
// SFSpeechRecognizer next to the AVAudioRecorder that makes the saved file; nothing here is ever saved.
// All callbacks arrive on the main queue.
@interface AutoJournalLiveTranscriber : NSObject

// Whole transcript so far (committed + the in-flight partial); fires on every change.
@property(nonatomic, copy, nullable) void (^onText)(NSString *text);
// The real reason capture or recognition failed; the recording itself is unaffected.
@property(nonatomic, copy, nullable) void (^onError)(NSString *message);

@property(nonatomic, copy, readonly) NSString *text;

// Starts (or resumes, appending to the same text). Requests speech authorization the first time.
- (void)start;
// Stops listening; the text stays so a resume appends.
- (void)stop;
// Stops and clears the text.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
