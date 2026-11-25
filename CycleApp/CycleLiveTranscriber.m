#import "CycleLiveTranscriber.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>


@implementation CycleLiveTranscriber {
    NSInteger _generation;   // bumps on every start/stop/reset; stale callbacks compare and bail
    BOOL _running;
    AVAudioEngine *_engine;
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_request;
    SFSpeechRecognitionTask *_task;
    NSString *_committed;    // finished tasks (a task ends at its time limit or on error)
    NSString *_partial;      // the current task's latest hypothesis
}

@synthesize onText, onError;

+ (NSString *)joinCommitted:(NSString *)committed partial:(NSString *)partial {
    if (committed.length == 0) return partial;
    if (partial.length == 0) return committed;
    return [NSString stringWithFormat:@"%@ %@", committed, partial];
}

- (instancetype)init {
    self = [super init];
    if (self) { _committed = @""; _partial = @""; }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self teardownCapture];
}

- (NSString *)text { return [CycleLiveTranscriber joinCommitted:_committed partial:_partial]; }

#pragma mark - Lifecycle

- (void)start {
    if (_running) return;
    _running = YES;
    NSInteger gen = ++_generation;
    __weak typeof(self) weakSelf = self;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CycleLiveTranscriber *s = weakSelf;
            if (!s || gen != s->_generation) return;
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [s failWithMessage:[NSString stringWithFormat:
                    @"speech recognition not authorized (SFSpeechRecognizerAuthorizationStatus %ld)", (long)status]];
                return;
            }
            [s beginCaptureGeneration:gen];
        });
    }];
}

- (void)stop {
    _generation++;
    _running = NO;
    [self teardownCapture];
    [self commitPartial];
}

- (void)reset {
    [self stop];
    _committed = @"";
    _partial = @"";
}

- (void)commitPartial {
    _committed = [CycleLiveTranscriber joinCommitted:_committed partial:_partial];
    _partial = @"";
}

- (void)failWithMessage:(NSString *)message {
    NSLog(@"[Cycle] live transcript error: %@", message);
    if (self.onError) self.onError(message);
}

#pragma mark - Capture

- (void)beginCaptureGeneration:(NSInteger)gen {
    _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    if (!_recognizer) { [self failWithMessage:@"no speech recogniser for en-US"]; return; }
    if (!_recognizer.isAvailable) { [self failWithMessage:@"speech recogniser for en-US is not available"]; return; }

    // CycleSpeech owns the session (Record) and its recorder is already running; this engine only taps the same input.
    // If the engine cannot start, the recorder wins and we only report onError.
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    _engine = engine;
    if (![self installTapAndStartEngine]) return;
    [self startTaskGeneration:gen];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(engineConfigurationChanged:)
                                                 name:AVAudioEngineConfigurationChangeNotification
                                               object:engine];
}

- (BOOL)installTapAndStartEngine {
    AVAudioFormat *format = [_engine.inputNode outputFormatForBus:0];
    NSLog(@"[Cycle] live transcript probe: input format %@ (sampleRate %.0f, channels %u)", format, format.sampleRate, format.channelCount);
    if (format.sampleRate == 0 || format.channelCount == 0) {
        [self failWithMessage:[NSString stringWithFormat:@"no audio input available (format %@)", format]];
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    [_engine.inputNode removeTapOnBus:0];
    [_engine.inputNode installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        // Audio thread; the request is swapped on the main queue when a task rolls over.
        [weakSelf appendBuffer:buffer];
    }];
    [_engine prepare];
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) {
        [_engine.inputNode removeTapOnBus:0];
        [self failWithMessage:[NSString stringWithFormat:@"audio engine start failed: %@ [%@ %ld]",
                               error.localizedDescription, error.domain, (long)error.code]];
        return NO;
    }
    NSLog(@"[Cycle] live transcript probe: engine running=%d alongside the recorder", _engine.isRunning);
    return YES;
}

- (void)appendBuffer:(AVAudioPCMBuffer *)buffer {
    [_request appendAudioPCMBuffer:buffer];
}

- (void)engineConfigurationChanged:(NSNotification *)note {
    if (!_running) return;
    NSLog(@"[Cycle] live transcript: engine configuration changed, restarting the tap");
    [self installTapAndStartEngine];
}

- (void)startTaskGeneration:(NSInteger)gen {
    SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    request.shouldReportPartialResults = YES;
    request.taskHint = SFSpeechRecognitionTaskHintDictation;
    if (_recognizer.supportsOnDeviceRecognition) request.requiresOnDeviceRecognition = YES;
    _request = request;
    __weak typeof(self) weakSelf = self;
    _task = [_recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf recognitionResult:result error:error request:request generation:gen];
        });
    }];
}

- (void)recognitionResult:(SFSpeechRecognitionResult *)result
                    error:(NSError *)error
                  request:(SFSpeechAudioBufferRecognitionRequest *)request
               generation:(NSInteger)gen {
    if (gen != _generation || request != _request) return; // from before a stop/resume or a rollover
    if (result) {
        _partial = result.bestTranscription.formattedString;
        if (self.onText) self.onText([self text]);
    }
    if (!result.isFinal && !error) return;

    // The task is over (time limit, silence timeout, or error): keep its text and start a fresh one on the same engine.
    [self commitPartial];
    [_task cancel];
    _task = nil;
    _request = nil;
    if (error) [self failWithMessage:[NSString stringWithFormat:@"%@ [%@ %ld]", error.localizedDescription, error.domain, (long)error.code]];
    if (self.onText) self.onText([self text]);
    // A failing task must not spin: wait a second before the replacement.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((error ? 1.0 : 0.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CycleLiveTranscriber *s = weakSelf;
        if (!s || gen != s->_generation) return;
        [s startTaskGeneration:gen];
    });
}

- (void)teardownCapture {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioEngineConfigurationChangeNotification object:nil];
    [_request endAudio];
    [_task cancel];
    _request = nil;
    _task = nil;
    if (_engine) {
        [_engine.inputNode removeTapOnBus:0];
        [_engine stop];
        _engine = nil;
    }
}

@end
