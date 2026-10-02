#import "ListenVoiceListener.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

#import "GLLog.h"
#import "ListenPlayer.h"

static NSTimeInterval const kListenVoiceWindowSeconds = 4.0;
static NSTimeInterval const kListenVoiceFinalizeSeconds = 1.2;

// Command vocabulary (PROTOCOL.md "Voice commands"). Phrases are stored
// accent-folded and lowercase; transcripts are folded the same way.
static NSArray<NSDictionary *> *ListenVocabulary(void) {
    return @[
        @{@"name": @"again",   @"en": @[@"again"],    @"es": @[@"otra vez"]},
        @{@"name": @"english", @"en": @[@"english"],  @"es": @[@"ingles"]},
        @{@"name": @"clear",   @"en": @[@"clear"],    @"es": @[@"claro"]},
        @{@"name": @"vocab",   @"en": @[@"vocab"],    @"es": @[@"vocabulario"]},
        @{@"name": @"next",    @"en": @[@"next"],     @"es": @[@"siguiente"]},
        @{@"name": @"back",    @"en": @[@"back"],     @"es": @[@"atras"]},
        @{@"name": @"save",    @"en": @[@"save"],     @"es": @[@"guardar"]},
        @{@"name": @"pause",   @"en": @[@"pause"],    @"es": @[@"pausa"]},
        @{@"name": @"play",    @"en": @[@"play"],     @"es": @[@"sigue"]},
        @{@"name": @"slower",  @"en": @[@"slower"],   @"es": @[@"mas lento"]},
        @{@"name": @"faster",  @"en": @[@"faster"],   @"es": @[@"mas rapido"]},
    ];
}

// Recogniser locale per vocabulary language: the "small table".
static NSArray<NSDictionary *> *ListenLocales(void) {
    return @[@{@"lang": @"es", @"locale": @"es-ES"}, @{@"lang": @"en", @"locale": @"en-US"}];
}

static NSString *ListenNormalize(NSString *s) {
    NSString *folded = [s stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil];
    NSCharacterSet *separators = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray *words = [[folded componentsSeparatedByCharactersInSet:separators] filteredArrayUsingPredicate:
                      [NSPredicate predicateWithFormat:@"length > 0"]];
    return [words componentsJoinedByString:@" "];
}

@implementation ListenVoiceListener {
    ListenPlayer *_player;
    NSInteger _generation;      // bumps on every start/cancel; stale callbacks compare and bail
    BOOL _listening;
    BOOL _wasPlaying;

    AVAudioEngine *_engine;
    NSArray<SFSpeechAudioBufferRecognitionRequest *> *_requests;
    NSArray<SFSpeechRecognitionTask *> *_tasks;
    NSMutableDictionary<NSString *, NSString *> *_transcripts;  // lang -> latest
    NSMutableSet<NSString *> *_finished;                        // langs whose task finished
    NSTimer *_windowTimer;
    NSTimer *_finalizeTimer;
    BOOL _audioEnded;
}

- (instancetype)initWithPlayer:(ListenPlayer *)player {
    self = [super init];
    if (self) _player = player;
    return self;
}

- (BOOL)listening { return _listening; }

#pragma mark - Matching

+ (NSString *)matchedCommandForTranscript:(NSString *)transcript {
    NSString *haystack = [NSString stringWithFormat:@" %@ ", ListenNormalize(transcript)];
    NSString *best = nil;
    NSUInteger bestLocation = NSNotFound;
    for (NSDictionary *entry in ListenVocabulary()) {
        for (NSString *lang in @[@"en", @"es"]) {
            for (NSString *phrase in entry[lang]) {
                NSRange r = [haystack rangeOfString:[NSString stringWithFormat:@" %@ ", phrase]];
                if (r.location != NSNotFound && r.location < bestLocation) {
                    bestLocation = r.location;
                    best = entry[@"name"];
                }
            }
        }
    }
    return best;
}

#pragma mark - Window

- (void)startWindow {
    if (_listening) return;
    NSInteger gen = ++_generation;
    __weak typeof(self) weakSelf = self;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ListenVoiceListener *strongSelf = weakSelf;
            if (!strongSelf || gen != strongSelf->_generation) return;
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [strongSelf failWithMessage:[NSString stringWithFormat:
                    @"speech recognition not authorized (SFSpeechRecognizerAuthorizationStatus %ld)", (long)status]];
                return;
            }
            [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ListenVoiceListener *s = weakSelf;
                    if (!s || gen != s->_generation) return;
                    if (!granted) { [s failWithMessage:@"microphone permission denied"]; return; }
                    [s beginCaptureGeneration:gen];
                });
            }];
        });
    }];
}

- (void)failWithMessage:(NSString *)message {
    GLLog(@"voice error: %@", message);
    if (self.onError) self.onError(message);
}

- (void)beginCaptureGeneration:(NSInteger)gen {
    NSMutableArray *requests = [NSMutableArray array];
    NSMutableArray *recognizers = [NSMutableArray array];
    NSMutableArray *langs = [NSMutableArray array];
    for (NSDictionary *entry in ListenLocales()) {
        SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:entry[@"locale"]]];
        if (!recognizer) { [self failWithMessage:[NSString stringWithFormat:@"no speech recogniser for locale %@", entry[@"locale"]]]; return; }
        if (!recognizer.isAvailable) { [self failWithMessage:[NSString stringWithFormat:@"speech recogniser for %@ is not available", entry[@"locale"]]]; return; }
        SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        request.shouldReportPartialResults = YES;
        request.taskHint = SFSpeechRecognitionTaskHintConfirmation;
        if (recognizer.supportsOnDeviceRecognition) request.requiresOnDeviceRecognition = YES;
        NSMutableArray *context = [NSMutableArray array];
        for (NSDictionary *vocab in ListenVocabulary()) [context addObjectsFromArray:vocab[entry[@"lang"]]];
        request.contextualStrings = context;
        [requests addObject:request];
        [recognizers addObject:recognizer];
        [langs addObject:entry[@"lang"]];
    }

    _wasPlaying = _player.playing;
    if (_wasPlaying) [_player pause];

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeMeasurement
                      options:AVAudioSessionCategoryOptionAllowBluetooth
                        error:&error] ||
        ![session setActive:YES error:&error]) {
        [self abortCapture];
        [self failWithMessage:[NSString stringWithFormat:@"audio session record failed: %@ [%@ %ld]",
                               error.localizedDescription, error.domain, (long)error.code]];
        return;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioFormat *format = [engine.inputNode outputFormatForBus:0];
    if (format.sampleRate == 0 || format.channelCount == 0) {
        [self abortCapture];
        [self failWithMessage:[NSString stringWithFormat:@"no audio input available (format %@)", format]];
        return;
    }
    NSArray *tapRequests = [requests copy];
    [engine.inputNode installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        for (SFSpeechAudioBufferRecognitionRequest *r in tapRequests) [r appendAudioPCMBuffer:buffer];
    }];
    [engine prepare];
    if (![engine startAndReturnError:&error]) {
        [engine.inputNode removeTapOnBus:0];
        [self abortCapture];
        [self failWithMessage:[NSString stringWithFormat:@"audio engine start failed: %@ [%@ %ld]",
                               error.localizedDescription, error.domain, (long)error.code]];
        return;
    }

    _engine = engine;
    _requests = tapRequests;
    _transcripts = [NSMutableDictionary dictionary];
    _finished = [NSMutableSet set];
    _audioEnded = NO;
    __weak typeof(self) weakSelf = self;
    NSMutableArray *tasks = [NSMutableArray array];
    for (NSUInteger i = 0; i < recognizers.count; i++) {
        NSString *lang = langs[i];
        SFSpeechRecognitionTask *task = [recognizers[i] recognitionTaskWithRequest:requests[i]
                                                                     resultHandler:^(SFSpeechRecognitionResult *result, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf recognitionUpdateGeneration:gen lang:lang result:result error:err];
            });
        }];
        [tasks addObject:task];
    }
    _tasks = tasks;

    _listening = YES;
    _windowTimer = [NSTimer scheduledTimerWithTimeInterval:kListenVoiceWindowSeconds repeats:NO block:^(NSTimer *t) {
        [weakSelf windowElapsedGeneration:gen];
    }];
    GLLog(@"voice window open (on-device es=%d en=%d)",
          ((SFSpeechRecognizer *)recognizers[0]).supportsOnDeviceRecognition,
          ((SFSpeechRecognizer *)recognizers[1]).supportsOnDeviceRecognition);
    if (self.onListeningChanged) self.onListeningChanged();
}

- (void)recognitionUpdateGeneration:(NSInteger)gen lang:(NSString *)lang result:(SFSpeechRecognitionResult *)result error:(NSError *)error {
    if (gen != _generation || !_listening) return;
    if (result) {
        _transcripts[lang] = result.bestTranscription.formattedString;
        if (result.isFinal) [_finished addObject:lang];
    }
    if (error) {
        // 1110 = "No speech detected", 301 = canceled: normal ends, not failures.
        GLLog(@"recognition %@ ended with error: %@ [%@ %ld]", lang, error.localizedDescription, error.domain, (long)error.code);
        [_finished addObject:lang];
        if (error.code != 1110 && error.code != 301) {
            [self failWithMessage:[NSString stringWithFormat:@"speech recognition (%@) failed: %@ [%@ %ld]",
                                   lang, error.localizedDescription, error.domain, (long)error.code]];
        }
    }
    if (_audioEnded && _finished.count == _tasks.count) [self concludeGeneration:gen];
}

- (void)windowElapsedGeneration:(NSInteger)gen {
    if (gen != _generation || !_listening) return;
    _windowTimer = nil;
    [self stopEngine];
    for (SFSpeechAudioBufferRecognitionRequest *r in _requests) [r endAudio];
    _audioEnded = YES;
    __weak typeof(self) weakSelf = self;
    _finalizeTimer = [NSTimer scheduledTimerWithTimeInterval:kListenVoiceFinalizeSeconds repeats:NO block:^(NSTimer *t) {
        [weakSelf concludeGeneration:gen];
    }];
}

- (void)stopEngine {
    if (!_engine) return;
    [_engine.inputNode removeTapOnBus:0];
    [_engine stop];
    _engine = nil;
}

/// Tears the window down and returns audio to playback. Does not touch playback state.
- (void)teardown {
    [_windowTimer invalidate]; _windowTimer = nil;
    [_finalizeTimer invalidate]; _finalizeTimer = nil;
    [self stopEngine];
    for (SFSpeechRecognitionTask *task in _tasks) [task cancel];
    _tasks = nil;
    _requests = nil;
    _listening = NO;
    [self restorePlaybackSession];
    if (self.onListeningChanged) self.onListeningChanged();
}

/// A failure after playback was paused for the window: put audio back as it was.
- (void)abortCapture {
    [self restorePlaybackSession];
    if (_wasPlaying) [self report:[_player play]];
    else [self releaseSession];
}

- (void)restorePlaybackSession {
    // Playback is re-activated by -[ListenPlayer play]; if nothing resumes, the
    // session is released so other apps' audio comes back.
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeSpokenAudio options:0 error:&error]) {
        [self failWithMessage:[NSString stringWithFormat:@"audio session restore to playback failed: %@ [%@ %ld]",
                               error.localizedDescription, error.domain, (long)error.code]];
    }
}

- (void)concludeGeneration:(NSInteger)gen {
    if (gen != _generation || !_listening) return;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *entry in ListenLocales()) {
        NSString *t = _transcripts[entry[@"lang"]];
        if (t.length && ![parts containsObject:t]) [parts addObject:t];
    }
    NSString *transcript = [parts componentsJoinedByString:@" / "];
    NSString *matched = nil;
    for (NSString *part in parts) {
        matched = [ListenVoiceListener matchedCommandForTranscript:part];
        if (matched) break;
    }
    BOOL wasPlaying = _wasPlaying;
    _generation++;
    [self teardown];
    if (self.onHeard) self.onHeard(transcript, matched);

    BOOL resume = wasPlaying && ![matched isEqual:@"pause"];
    if (resume) [self report:[_player play]];
    else if (!wasPlaying) [self releaseSession];
    if (matched) [self execute:matched];
}

- (void)cancel {
    if (!_listening) { _generation++; return; }
    BOOL wasPlaying = _wasPlaying;
    _generation++;
    [self teardown];
    if (wasPlaying) [self report:[_player play]];
    else [self releaseSession];
}

- (void)releaseSession {
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setActive:NO
                                        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                              error:&error]) {
        GLLog(@"audio session deactivate after voice failed: %@ [%@ %ld]", error.localizedDescription, error.domain, (long)error.code);
    }
}

#pragma mark - Actions

- (void)report:(NSString *)error {
    if (error) [self failWithMessage:error];
}

- (void)execute:(NSString *)name {
    if ([name isEqual:@"again"]) [self report:[_player replay:@"original"]];
    else if ([name isEqual:@"english"]) [self report:[_player replay:@"translation"]];
    else if ([name isEqual:@"clear"]) [self report:[_player replay:@"clear"]];
    else if ([name isEqual:@"vocab"]) [self report:[_player replay:@"vocab"]];
    else if ([name isEqual:@"next"]) [self report:[_player next]];
    else if ([name isEqual:@"back"]) [self report:[_player prev]];
    else if ([name isEqual:@"save"]) { if (self.onCommand) self.onCommand(@"save", _player.currentIdx); }
    else if ([name isEqual:@"pause"]) [self report:[_player pause]];
    else if ([name isEqual:@"play"]) { if (!_player.playing) [self report:[_player play]]; }
    else if ([name isEqual:@"slower"]) [self report:[_player adjustRateBy:-0.1]];
    else if ([name isEqual:@"faster"]) [self report:[_player adjustRateBy:0.1]];
}

@end
