#import "GripesVoiceListener.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

@interface GripesVoiceListener ()
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, assign) NSUInteger generation; // drops callbacks from a task that was already stopped
@end

@implementation GripesVoiceListener

- (void)fail:(NSString *)message {
    NSLog(@"[Gripes] voice: %@", message);
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onError) self.onError(message); });
}

- (void)startPreferringOnDevice:(BOOL)onDevice {
    [self stop];
    NSUInteger gen = self.generation;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            [self fail:[NSString stringWithFormat:@"Speech recognition is not allowed (status %ld). Enable it in Settings > Gripes.", (long)status]];
            return;
        }
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            if (!granted) { [self fail:@"Microphone access is not allowed. Enable it in Settings > Gripes."]; return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != self.generation) return; // stopped while the permission prompts were up
                [self beginCaptureOnDevice:onDevice generation:gen];
            });
        }];
    }];
}

- (void)beginCaptureOnDevice:(BOOL)onDevice generation:(NSUInteger)gen {
    SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    if (!recognizer.isAvailable) { [self fail:@"The speech recognizer is unavailable right now."]; return; }
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionDuckOthers error:&error] ||
        ![session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
        [self fail:[NSString stringWithFormat:@"Audio session failed: %@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code]];
        return;
    }
    SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    request.shouldReportPartialResults = YES;
    if (onDevice && recognizer.supportsOnDeviceRecognition) request.requiresOnDeviceRecognition = YES;

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    [input installTapOnBus:0 bufferSize:1024 format:[input outputFormatForBus:0] block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [request appendAudioPCMBuffer:buffer];
    }];
    [engine prepare];
    if (![engine startAndReturnError:&error]) {
        [input removeTapOnBus:0];
        [self fail:[NSString stringWithFormat:@"Audio engine failed to start: %@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code]];
        return;
    }
    self.recognizer = recognizer; self.engine = engine; self.request = request;
    self.task = [recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self.generation) return;
            if (result && self.onText) self.onText(result.bestTranscription.formattedString, result.isFinal);
            // 1110 = no speech detected, 301 = cancelled: normal ends, not failures.
            if (err && !(([err.domain isEqualToString:@"kAFAssistantErrorDomain"]) && (err.code == 1110 || err.code == 301))) {
                [self fail:[NSString stringWithFormat:@"Recognition failed: %@ (%@ %ld)", err.localizedDescription, err.domain, (long)err.code]];
            }
        });
    }];
}

- (void)stop {
    self.generation++;
    BOOL wasCapturing = self.engine != nil;
    if (self.engine.isRunning) [self.engine stop];
    [self.engine.inputNode removeTapOnBus:0];
    [self.request endAudio];
    [self.task cancel];
    self.engine = nil; self.request = nil; self.task = nil; self.recognizer = nil;
    if (!wasCapturing) return; // nothing was started, so there is no audio session to release
    NSError *error = nil;
    if (![AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
        NSLog(@"[Gripes] could not deactivate audio session: %@", error);
    }
}

@end
