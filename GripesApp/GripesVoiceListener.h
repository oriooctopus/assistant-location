#import <Foundation/Foundation.h>

/// Live speech-to-text for the Gripes voice entry: SFSpeechRecognizer fed by an AVAudioEngine tap,
/// partial results streamed to `onText`. Prefers on-device recognition when the device supports it.
@interface GripesVoiceListener : NSObject

/// Called on the main queue with the full transcript so far.
@property (nonatomic, copy) void (^onText)(NSString *text, BOOL isFinal);
/// Called on the main queue with a user-readable reason (permission denied, recognizer down, ...).
@property (nonatomic, copy) void (^onError)(NSString *message);

- (void)startPreferringOnDevice:(BOOL)onDevice;
- (void)stop;

@end
