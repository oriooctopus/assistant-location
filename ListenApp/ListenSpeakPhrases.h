// ListenSpeakPhrases: the spoken control words a native Listen & speak turn listens for while recording, matched
// against the on-device recognizer's transcript (ListenSpeakTurn -recognitionGen:). Plain Foundation, no audio, so
// SharedTests can cover the matching (ListenSpeakPhrasesTests).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ListenSpeakPhrases : NSObject

/// YES when the transcript ENDS with "I'm done" / "I am done" / "im done" (case, apostrophe style and trailing
/// punctuation ignored). Tail only, so "I'm done with the first part" does not match. Ends a summary answer.
+ (BOOL)transcriptEndsWithDone:(NSString *)transcript;

/// YES when the transcript is nothing but "continue" (case and punctuation ignored): the listener wants to skip this
/// stop and have playback carry on. Whole-transcript only, so an answer that merely contains the word ("the story
/// will continue tomorrow") is still graded.
+ (BOOL)transcriptIsContinue:(NSString *)transcript;

@end

NS_ASSUME_NONNULL_END
