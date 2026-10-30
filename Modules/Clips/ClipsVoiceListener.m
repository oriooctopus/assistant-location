#import "ClipsVoiceListener.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

#import "GLLog.h"

@interface ClipsVoiceListener ()
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic) NSUInteger generation; // drops callbacks from a task that was already stopped
@end

@implementation ClipsVoiceListener

- (void)fail:(NSString *)message {
    GLLog(@"clips voice: %@", message);
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onError) self.onError(message); });
}

- (void)start {
    [self stop];
    NSUInteger gen = self.generation;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            [self fail:[NSString stringWithFormat:@"Speech recognition not allowed (status %ld)", (long)status]];
            return;
        }
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            if (!granted) { [self fail:@"Microphone not allowed"]; return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != self.generation) return; // stopped while the permission prompts were up
                [self beginCaptureWithGeneration:gen];
            });
        }];
    }];
}

- (void)beginCaptureWithGeneration:(NSUInteger)gen {
    SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    if (!recognizer.isAvailable) { [self fail:@"Speech recognizer unavailable"]; return; }
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:0 error:&error] ||
        ![session setActive:YES error:&error]) {
        [self fail:[NSString stringWithFormat:@"Audio session: %@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code]];
        return;
    }
    SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    request.shouldReportPartialResults = YES;
    if (recognizer.supportsOnDeviceRecognition) request.requiresOnDeviceRecognition = YES;

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    [input installTapOnBus:0 bufferSize:1024 format:[input outputFormatForBus:0] block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [request appendAudioPCMBuffer:buffer];
    }];
    [engine prepare];
    if (![engine startAndReturnError:&error]) {
        [input removeTapOnBus:0];
        [self fail:[NSString stringWithFormat:@"Audio engine: %@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code]];
        return;
    }
    self.recognizer = recognizer; self.engine = engine; self.request = request;
    self.task = [recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self.generation) return;
            if (result && self.onText) self.onText(result.bestTranscription.formattedString, result.isFinal);
            if (!err) return;
            BOOL noSpeech = [err.domain isEqualToString:@"kAFAssistantErrorDomain"] && err.code == 1110;
            [self fail:noSpeech ? @"No speech heard" : [NSString stringWithFormat:@"Recognition: %@ (%@ %ld)", err.localizedDescription, err.domain, (long)err.code]];
        });
    }];
}

- (void)stop {
    self.generation++;
    if (self.engine.isRunning) [self.engine stop];
    [self.engine.inputNode removeTapOnBus:0];
    [self.request endAudio];
    [self.task cancel];
    self.engine = nil; self.request = nil; self.task = nil; self.recognizer = nil;
}

@end
