#import <Foundation/Foundation.h>

/// Voice capture for a page field or Talk (bridge `speech.start` / `speech.stop` / `speech.cancel`): records the microphone
/// to an m4a (AAC, 16 kHz mono). The page uploads the clip to the Cycle box, which transcribes it with Deepgram, so no
/// recognition happens on the device. The recording lives in Application Support/CycleVoice until `ackClip:` or `cancel` deletes it.
@interface CycleSpeech : NSObject

/// Main queue. Once speech has been heard and then silence has held for a while (thresholds are guesses, see the .m).
@property (nonatomic, copy) void (^onSilence)(void);
/// Main queue. A short user-facing reason a running recording failed.
@property (nonatomic, copy) void (^onError)(NSString *message);

/// Asks for the microphone permission on first use, then starts recording. `done(nil)` once recording, else
/// `done(@"Mic off")` when denied or `done(<short reason>)` ("Mic busy"). Main queue, exactly once.
- (void)startWithCompletion:(void (^)(NSString *error))done;
/// Where recordings live (default Application Support/CycleVoice). Settable for tests; set before the first recording.
@property (nonatomic, strong) NSURL *voiceDirectory;
/// Stops recording and returns {id: NSString, audio: NSData}; nil when nothing was recording (or it was empty). The file is
/// kept until -ackClip: with that id. Releases the microphone and the audio session.
- (NSDictionary *)finishClip;
/// Deletes a kept clip once the page has saved its own copy. NO for an id that is not a plain clip id; YES when already gone.
- (BOOL)ackClip:(NSString *)clipID;
/// Every kept clip nobody acked (the page died first, or the app was killed mid-recording), as {id, audio}. The recording in
/// progress is not listed. Empty files are deleted.
- (NSArray<NSDictionary *> *)orphanClips;
/// Stops recording and deletes the file. Safe when idle.
- (void)cancel;
/// The app went to the background: iOS stops the microphone, so finalize the file and keep it for the pending `finishClip`,
/// and report silence so Talk ends its turn. A dictated field keeps its mic lit until the person taps it.
- (void)interrupt;

@end
