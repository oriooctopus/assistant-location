#import <Foundation/Foundation.h>

/// Live speech-to-text for the Clips player: SFSpeechRecognizer fed by an AVAudioEngine tap,
/// on-device when the phone supports it, so a note works with no connection. Takes the audio
/// session for recording and leaves it that way; the player sets its own category back.
@interface ClipsVoiceListener : NSObject

/// Called on the main queue with the full transcript so far.
@property (nonatomic, copy) void (^onText)(NSString *text, BOOL isFinal);
/// Called on the main queue with a user-readable reason (permission denied, recognizer down, ...).
@property (nonatomic, copy) void (^onError)(NSString *message);

- (void)start;
- (void)stop;

@end
