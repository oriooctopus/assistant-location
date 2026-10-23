#import "ListenSpeakTurn.h"

#import <AVFoundation/AVFoundation.h>

#import "GLLog.h"

// Tuning values. None of these were measured on a device: they are first guesses to adjust after one real try.
/// Give up (and park paused at the next section) if nothing above kSpeechDb was heard this long after recording began.
static NSTimeInterval const kNoSpeechGiveUp = 8.0;
/// After speech has started, this much continuous quiet ends the answer.
static NSTimeInterval const kSilenceEnd = 1.8;
/// Hard caps on the answer length, per stop kind.
static NSTimeInterval const kRepeatCap = 20.0;
static NSTimeInterval const kSummaryCap = 90.0;
/// AVAudioRecorder averagePowerForChannel threshold (dBFS) above which we call it speech. GUESS: room noise on an
/// iPhone mic sits around -50..-60, speech held near the phone or an AirPods mic around -30..-10, so -38 should split
/// them, but a noisy street or a pocket-muffled phone may need this moved.
static float const kSpeechDb = -38.0f;
static NSTimeInterval const kMeterInterval = 0.1;
/// Grading is a transcription plus a claude call plus TTS on the server; generous so a slow one is not cut off.
static NSTimeInterval const kGradeTimeout = 120.0;

@interface ListenSpeakTurn () <AVAudioPlayerDelegate>
@end

@implementation ListenSpeakTurn {
    NSURL *_base;
    NSString *_phase;
    NSInteger _gen;              // bumped on every start / retry / teardown: a callback from an older one is ignored
    NSString *_itemId;
    NSDictionary *_stop;
    AVAudioPlayer *_audio;       // prompt or feedback
    NSInteger _audioGen;
    void (^_audioDone)(void);
    AVAudioRecorder *_recorder;
    NSTimer *_meterTimer;
    NSURL *_recordingURL;
    BOOL _spoke;
    NSTimeInterval _recordStart; // systemUptime
    NSTimeInterval _lastLoud;
    NSURLSessionTask *_task;
    AVAudioPlayer *_keepAlive;   // looping silence for the whole turn, see -startKeepAlive
}

- (instancetype)initWithBaseURL:(NSURL *)base {
    self = [super init];
    if (self) _base = base;
    return self;
}

- (NSString *)phase { return _phase; }

- (void)setPhaseName:(NSString *)phase {
    _phase = [phase copy];
    GLLog(@"speak turn phase=%@", phase);
    if (self.onPhaseChanged) self.onPhaseChanged();
}

#pragma mark - Entry points

- (BOOL)startWithItemId:(NSString *)itemId stop:(NSDictionary *)stop {
    if (_phase) return NO;
    _itemId = [itemId copy];
    _stop = [stop copy];
    NSInteger gen = ++_gen;
    [self setPhaseName:@"prompt"]; // set synchronously: the player publishes State right after the handler returns
    __weak typeof(self) weakSelf = self;
    // Asked before the prompt is spoken so a denied mic fails at once instead of after a prompt nobody can answer.
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ListenSpeakTurn *s = weakSelf;
            if (!s || gen != s->_gen) return;
            if (!granted) { [s completeWithError:@"microphone permission denied"]; return; }
            [s beginPromptGen:gen];
        });
    }];
    return YES;
}

- (BOOL)retryFromFeedback {
    if (![_phase isEqual:@"feedback"]) return NO;
    NSInteger gen = ++_gen; // invalidates the feedback player's completion
    [self stopAudio];
    GLLog(@"speak turn retry");
    [self startRecordingGen:gen];
    return YES;
}

- (void)cancel {
    if (!_phase) return;
    [self teardown];
    [self setPhaseName:nil];
}

#pragma mark - 1. Prompt

/// Switches the (still active) audio session to playAndRecord, then fetches and speaks the prompt.
/// LOAD-BEARING: setActive:YES here is a re-activation of a session ListenPlayer deliberately left active; if the
/// session had been deactivated at the section end, iOS would refuse the later record start while backgrounded.
- (void)beginPromptGen:(NSInteger)gen {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    // DefaultToSpeaker: playAndRecord otherwise routes playback to the quiet earpiece receiver.
    // AllowBluetooth: AirPods route (same option ListenVoiceListener uses).
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeDefault
                      options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                        error:&error] ||
        ![session setActive:YES error:&error]) {
        [self completeWithError:[NSString stringWithFormat:@"audio session record failed: %@ [%@ %ld]",
                                 error.localizedDescription, error.domain, (long)error.code]];
        return;
    }
    [self startKeepAlive];
    NSURLComponents *c = [NSURLComponents componentsWithURL:[NSURL URLWithString:@"api/speak/prompt.mp3" relativeToURL:_base]
                                    resolvingAgainstBaseURL:YES];
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"item" value:_itemId],
                     [NSURLQueryItem queryItemWithName:@"kind" value:_stop[@"kind"]]];
    __weak typeof(self) weakSelf = self;
    [self fetchRequest:[NSURLRequest requestWithURL:c.URL] what:@"prompt" gen:gen done:^(NSData *data) {
        ListenSpeakTurn *s = weakSelf;
        [s playData:data gen:gen what:@"prompt" then:^{ [s startRecordingGen:gen]; }];
    }];
}

#pragma mark - 2. Recording

/// Starts the metered recorder. Also the retry entry point (the session is already playAndRecord by then).
- (void)startRecordingGen:(NSInteger)gen {
    [self setPhaseName:@"recording"];
    NSString *name = [NSString stringWithFormat:@"listen-speak-%@.m4a", [NSUUID UUID].UUIDString];
    _recordingURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                               AVSampleRateKey: @16000,      // speech; the transcriber does not need more
                               AVNumberOfChannelsKey: @1,
                               AVEncoderAudioQualityKey: @(AVAudioQualityMedium)};
    NSError *error = nil;
    _recorder = [[AVAudioRecorder alloc] initWithURL:_recordingURL settings:settings error:&error];
    if (!_recorder) {
        [self completeWithError:[NSString stringWithFormat:@"could not create the recorder: %@ [%@ %ld]",
                                 error.localizedDescription, error.domain, (long)error.code]];
        return;
    }
    _recorder.meteringEnabled = YES;
    if (![_recorder record]) {
        [self completeWithError:@"could not start recording (the audio session may have been taken by another app)"];
        return;
    }
    _spoke = NO;
    _recordStart = [NSProcessInfo processInfo].systemUptime;
    _lastLoud = _recordStart;
    __weak typeof(self) weakSelf = self;
    _meterTimer = [NSTimer scheduledTimerWithTimeInterval:kMeterInterval repeats:YES block:^(NSTimer *timer) {
        [weakSelf meterTickGen:gen];
    }];
}

/// Every kMeterInterval: decides whether the answer has started, ended (silence / cap) or been abandoned (no speech).
- (void)meterTickGen:(NSInteger)gen {
    if (gen != _gen || !_recorder) return;
    if (!_recorder.recording) {
        // A phone call or another app took the session and iOS stopped the recorder under us.
        [self completeWithError:@"recording was interrupted"];
        return;
    }
    [_recorder updateMeters];
    float db = [_recorder averagePowerForChannel:0];
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    NSTimeInterval elapsed = now - _recordStart;
    if (db > kSpeechDb) { _spoke = YES; _lastLoud = now; }
    if (!_spoke) {
        if (elapsed >= kNoSpeechGiveUp) {
            GLLog(@"speak turn: no speech in %.0fs, parking paused at the next section", kNoSpeechGiveUp);
            [self completeWithError:nil];
        }
        return;
    }
    NSTimeInterval cap = [_stop[@"kind"] isEqual:@"summary"] ? kSummaryCap : kRepeatCap;
    if (now - _lastLoud >= kSilenceEnd || elapsed >= cap) [self endRecordingGen:gen];
}

#pragma mark - 3. Grading

- (void)endRecordingGen:(NSInteger)gen {
    [_meterTimer invalidate];
    _meterTimer = nil;
    [_recorder stop];
    _recorder = nil;
    NSError *error = nil;
    NSData *audio = [NSData dataWithContentsOfURL:_recordingURL options:0 error:&error];
    if (!audio.length) {
        [self completeWithError:[NSString stringWithFormat:@"recording file is empty or unreadable: %@", error.localizedDescription ?: @"0 bytes"]];
        return;
    }
    // Read into memory, so the file can go now; a retry records into a fresh one and would otherwise orphan this one.
    NSError *rmError = nil;
    if (![[NSFileManager defaultManager] removeItemAtURL:_recordingURL error:&rmError]) {
        GLLog(@"speak turn: could not delete %@: %@", _recordingURL.lastPathComponent, rmError.localizedDescription);
    }
    _recordingURL = nil;
    [self setPhaseName:@"grading"];
    NSURLComponents *c = [NSURLComponents componentsWithURL:[NSURL URLWithString:@"api/speak/grade" relativeToURL:_base]
                                    resolvingAgainstBaseURL:YES];
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"item" value:_itemId],
                     [NSURLQueryItem queryItemWithName:@"kind" value:_stop[@"kind"]],
                     [NSURLQueryItem queryItemWithName:@"from" value:[_stop[@"from"] stringValue]],
                     [NSURLQueryItem queryItemWithName:@"to" value:[_stop[@"to"] stringValue]],
                     // One opId per attempt: the server dedupes a replay of the same one, a retry is a new attempt.
                     [NSURLQueryItem queryItemWithName:@"opId" value:[NSUUID UUID].UUIDString],
                     [NSURLQueryItem queryItemWithName:@"speak" value:@"1"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:c.URL];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = kGradeTimeout;
    [request setValue:@"audio/mp4" forHTTPHeaderField:@"Content-Type"];
    __weak typeof(self) weakSelf = self;
    NSURLSessionUploadTask *task = [[NSURLSession sharedSession] uploadTaskWithRequest:request fromData:audio
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ListenSpeakTurn *s = weakSelf;
                if (!s || gen != s->_gen) return;
                NSString *failure = [ListenSpeakTurn failureForResponse:response data:data error:netError what:@"grade"];
                if (failure) { [s completeWithError:failure]; return; }
                NSError *jsonError = nil;
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                NSString *feedbackPath = [json isKindOfClass:[NSDictionary class]] ? json[@"feedbackAudioUrl"] : nil;
                if (![feedbackPath isKindOfClass:[NSString class]]) {
                    [s completeWithError:[NSString stringWithFormat:@"grade reply has no feedbackAudioUrl (%@)",
                                          jsonError.localizedDescription ?: @"unexpected JSON"]];
                    return;
                }
                if (s.onResult) s.onResult(json);
                [s playFeedbackAtPath:feedbackPath gen:gen];
            });
        }];
    _task = task;
    [task resume];
}

#pragma mark - 4. Feedback

- (void)playFeedbackAtPath:(NSString *)path gen:(NSInteger)gen {
    [self setPhaseName:@"feedback"];
    NSURL *url = [NSURL URLWithString:path relativeToURL:_base].absoluteURL;
    if (!url) { [self completeWithError:[NSString stringWithFormat:@"bad feedbackAudioUrl %@", path]]; return; }
    __weak typeof(self) weakSelf = self;
    [self fetchRequest:[NSURLRequest requestWithURL:url] what:@"feedback" gen:gen done:^(NSData *data) {
        ListenSpeakTurn *s = weakSelf;
        [s playData:data gen:gen what:@"feedback" then:^{ [s completeWithError:nil]; }];
    }];
}

#pragma mark - Networking and playback helpers

/// GETs `request`; on a 200 calls `done` with the body (main queue), otherwise ends the turn with the real reason.
/// A reply for an older generation (the turn was retried / cancelled meanwhile) is dropped.
- (void)fetchRequest:(NSURLRequest *)request what:(NSString *)what gen:(NSInteger)gen done:(void (^)(NSData *data))done {
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ListenSpeakTurn *s = weakSelf;
                if (!s || gen != s->_gen) return;
                NSString *failure = [ListenSpeakTurn failureForResponse:response data:data error:netError what:what];
                if (failure) { [s completeWithError:failure]; return; }
                done(data);
            });
        }];
    _task = task;
    [task resume];
}

/// nil when the response is a 200 with a body; otherwise a message carrying the server's own {"error": ...} text when
/// there is one (the server answers 4xx/5xx with that shape).
+ (NSString *)failureForResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)netError what:(NSString *)what {
    if (netError) {
        return [NSString stringWithFormat:@"speak %@ request failed: %@ [%@ %ld]", what, netError.localizedDescription,
                netError.domain, (long)netError.code];
    }
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    if (status == 200 && data.length > 0) return nil;
    NSString *detail = nil;
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"error"] isKindOfClass:[NSString class]]) detail = json[@"error"];
    return [NSString stringWithFormat:@"speak %@ failed (HTTP %ld): %@", what, (long)status, detail ?: @"empty or non-JSON body"];
}

/// Plays mp3 `data` through AVAudioPlayer and calls `then` when it ends. Decode and playback failures end the turn.
- (void)playData:(NSData *)data gen:(NSInteger)gen what:(NSString *)what then:(void (^)(void))then {
    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:data fileTypeHint:AVFileTypeMPEGLayer3 error:&error];
    if (!player) {
        [self completeWithError:[NSString stringWithFormat:@"could not decode the %@ audio: %@ [%@ %ld]", what,
                                 error.localizedDescription, error.domain, (long)error.code]];
        return;
    }
    player.delegate = self;
    _audio = player;
    _audioGen = gen;
    _audioDone = [then copy];
    if (![player play]) [self completeWithError:[NSString stringWithFormat:@"could not play the %@ audio", what]];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != _audio || _audioGen != _gen) return; // a cut-off (retry / cancel) player reports here too
    void (^done)(void) = _audioDone;
    _audioDone = nil;
    _audio = nil;
    if (!flag) { [self completeWithError:@"audio playback ended with an error"]; return; }
    done();
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if (player != _audio || _audioGen != _gen) return;
    [self completeWithError:[NSString stringWithFormat:@"audio decode error: %@", error.localizedDescription]];
}

- (void)stopAudio {
    _audioDone = nil;
    _audio.delegate = nil; // a stopped player must not call -audioPlayerDidFinishPlaying back into a newer phase
    [_audio stop];
    _audio = nil;
}

#pragma mark - Keep-alive

/// LOAD-BEARING: iOS keeps a backgrounded app running only while its audio session is actually playing or recording.
/// The prompt fetch and above all grading (transcription + claude + TTS, often 10-30 s) have neither, so without this
/// the app is suspended mid-turn with the screen locked and the feedback never plays. A looping 1 s buffer of digital
/// silence runs from the prompt until teardown; it is inaudible and does not disturb the recorder.
- (void)startKeepAlive {
    if (_keepAlive) return;
    // 1 s of 16-bit mono 8 kHz PCM zeros in a WAV container (44-byte header + data).
    uint32_t rate = 8000, dataLen = rate * 2;
    NSMutableData *wav = [NSMutableData dataWithLength:44 + dataLen];
    uint8_t *b = wav.mutableBytes;
    memcpy(b, "RIFF", 4); uint32_t riff = 36 + dataLen; memcpy(b + 4, &riff, 4);
    memcpy(b + 8, "WAVEfmt ", 8);
    uint32_t fmtLen = 16; memcpy(b + 16, &fmtLen, 4);
    uint16_t pcm = 1, channels = 1, align = 2, bits = 16; uint32_t byteRate = rate * 2;
    memcpy(b + 20, &pcm, 2); memcpy(b + 22, &channels, 2); memcpy(b + 24, &rate, 4);
    memcpy(b + 28, &byteRate, 4); memcpy(b + 32, &align, 2); memcpy(b + 34, &bits, 2);
    memcpy(b + 36, "data", 4); memcpy(b + 40, &dataLen, 4);
    NSError *error = nil;
    _keepAlive = [[AVAudioPlayer alloc] initWithData:wav fileTypeHint:AVFileTypeWAVE error:&error];
    if (!_keepAlive) { GLLog(@"speak turn: keep-alive player failed: %@", error.localizedDescription); return; }
    _keepAlive.numberOfLoops = -1;
    if (![_keepAlive play]) GLLog(@"speak turn: keep-alive did not start");
}

#pragma mark - Ending

/// Stops everything in flight and invalidates its callbacks. Safe to call when idle.
- (void)teardown {
    _gen++;
    [_meterTimer invalidate];
    _meterTimer = nil;
    [_recorder stop];
    _recorder = nil;
    [_task cancel];
    _task = nil;
    [self stopAudio];
    [_keepAlive stop];
    _keepAlive = nil;
    if (_recordingURL) {
        // The temp file is useless once the turn is over; a failed delete only leaves a small file in tmp/.
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:_recordingURL error:&error]) {
            GLLog(@"speak turn: could not delete %@: %@", _recordingURL.lastPathComponent, error.localizedDescription);
        }
        _recordingURL = nil;
    }
}

/// Ends the turn: with `error` non-nil it is reported first. Either way onFinished then parks the player PAUSED at the
/// next section (it never resumes by itself), so the listener can press play from the lock screen after any outcome.
- (void)completeWithError:(NSString *)error {
    NSInteger afterIdx = [_stop[@"afterIdx"] integerValue];
    [self teardown];
    [self setPhaseName:nil];
    if (error) {
        GLLog(@"speak turn error: %@", error);
        if (self.onError) self.onError(error);
    }
    if (self.onFinished) self.onFinished(afterIdx);
}

@end
