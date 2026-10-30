#import "CycleSpeech.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

@interface CycleSpeech ()
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, copy) NSString *lastText;
@property (nonatomic, assign) NSUInteger generation; // drops callbacks from a capture that was already stopped
@end

@implementation CycleSpeech

- (void)startWithCompletion:(void (^)(NSString *))done {
    [self stop];
    NSUInteger gen = self.generation;
    void (^finish)(NSString *) = ^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(error); });
    };
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            NSLog(@"[Cycle] speech authorization status %ld", (long)status);
            finish(@"Mic off");
            return;
        }
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            if (!granted) { NSLog(@"[Cycle] microphone permission denied"); finish(@"Mic off"); return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != self.generation) { done(@"Speech stopped"); return; } // stopped while the prompts were up
                done([self beginCaptureGeneration:gen]);
            });
        }];
    }];
}

/// Returns nil once capturing, else the short reason.
- (NSString *)beginCaptureGeneration:(NSUInteger)gen {
    SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    if (!recognizer.isAvailable) { NSLog(@"[Cycle] speech recognizer unavailable"); return @"Speech unavailable"; }
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionDuckOthers error:&error] ||
        ![session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
        NSLog(@"[Cycle] audio session failed: %@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code);
        return @"Mic busy";
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
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
        NSLog(@"[Cycle] audio engine failed: %@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code);
        return @"Mic busy";
    }
    self.recognizer = recognizer; self.engine = engine; self.request = request; self.lastText = @"";
    self.task = [recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self.generation) return;
            if (result) {
                self.lastText = result.bestTranscription.formattedString;
                if (self.onText) self.onText(self.lastText, result.isFinal);
                if (result.isFinal) { [self stop]; return; }
            }
            if (!err) return;
            // 1110 = no speech detected, 301 = cancelled: normal ends, not failures.
            BOOL normal = [err.domain isEqualToString:@"kAFAssistantErrorDomain"] && (err.code == 1110 || err.code == 301);
            NSLog(@"[Cycle] recognition ended: %@ (%@ %ld)", err.localizedDescription, err.domain, (long)err.code);
            [self stop];
            if (normal) { if (self.onText) self.onText(self.lastText, YES); }
            else if (self.onError) self.onError(@"Speech failed");
        });
    }];
    return nil;
}

- (void)stop {
    self.generation++;
    BOOL wasCapturing = self.engine != nil;
    if (self.engine.isRunning) [self.engine stop];
    [self.engine.inputNode removeTapOnBus:0];
    [self.request endAudio];
    [self.task cancel];
    self.engine = nil; self.request = nil; self.task = nil; self.recognizer = nil;
    if (!wasCapturing) return;
    NSError *error = nil;
    if (![AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error]) {
        NSLog(@"[Cycle] could not deactivate audio session: %@", error);
    }
}

@end
