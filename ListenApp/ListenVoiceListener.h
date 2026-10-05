// ListenVoiceListener: the in-app voice command window from PROTOCOL.md.
// On-device SFSpeechRecognizer (es + en, run side by side on the same audio),
// a 4 s window, the mic opened only inside it. Playback is paused for the
// window (the mic would hear it) and restored afterwards; the audio session
// goes playAndRecord for the window and back to playback-only after.

#import <Foundation/Foundation.h>

@class ListenPlayer;

NS_ASSUME_NONNULL_BEGIN

@interface ListenVoiceListener : NSObject

@property (nonatomic, readonly) BOOL listening;
/// Main queue. YES when the window opens, NO when it closes.
@property (nonatomic, copy, nullable) void (^onListeningChanged)(void);
/// Main queue. `matched` is the canonical command name or nil.
@property (nonatomic, copy, nullable) void (^onHeard)(NSString *transcript, NSString *_Nullable matched);
/// Main queue. Commands the page must execute (currently only `save`).
@property (nonatomic, copy, nullable) void (^onCommand)(NSString *name, NSInteger idx);
/// Main queue. Permission, recogniser and audio failures, with the real reason.
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);

- (instancetype)initWithPlayer:(ListenPlayer *)player NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Opens the 4 s listening window. No-op while one is already open.
- (void)startWindow;
/// Closes the window without acting on anything heard.
- (void)cancel;

/// Matches a transcript against the vocabulary table (either language,
/// accent-insensitive, whole words, earliest hit wins). Exposed for tests.
+ (nullable NSString *)matchedCommandForTranscript:(NSString *)transcript;

@end

NS_ASSUME_NONNULL_END
