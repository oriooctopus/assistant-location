#import "ListenPlayer.h"

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

#import "GLLog.h"

static NSTimeInterval const kListenGapSeconds = 0.4;
static NSTimeInterval const kListenStateTickSeconds = 0.25;
static NSInteger const kListenPrefetchCount = 2;
static void *ListenItemStatusContext = &ListenItemStatusContext;

@implementation ListenPlayer {
    AVQueuePlayer *_player;
    NSMutableDictionary<NSURL *, AVURLAsset *> *_assets;

    // Loaded item.
    NSString *_itemId;
    NSString *_title;
    NSArray<NSDictionary *> *_sections;
    NSDictionary *_settings;

    // Loop position.
    NSInteger _idx;
    NSInteger _stepIdx;      // index into -effectiveStepsForIdx:_idx
    NSInteger _repeatDone;   // completed repeats of `original` in this step
    BOOL _finished;          // section ended without autoAdvance; step is null
    BOOL _playing;           // the loop wants audio
    NSString *_replayKind;   // one-off replay clip in flight
    BOOL _resumeAfterReplay;
    NSString *_replayThen;   // clip kind to play right after the current replay ends
    double _replaySlowdown;  // fraction slower than settings.rate for the current `original` replay

    // Current clip.
    AVPlayerItem *_currentItem;
    NSArray *_itemObservers;
    NSString *_clipKind;
    double _clipStart;
    double _clipEnd;
    double _clipRate;
    BOOL _clipReady;         // status ready and seeked to the clip start
    BOOL _clipEnded;         // played to its end (or discarded); next play restarts the step

    NSTimer *_gapTimer;
    NSTimer *_stateTimer;
    NSString *_lastError;
    BOOL _remoteCommandsRegistered;
    BOOL _resumeAfterInterruption;
}

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _player = [[AVQueuePlayer alloc] init];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        _assets = [NSMutableDictionary dictionary];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(audioSessionInterruption:)
                   name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(audioRouteChanged:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_gapTimer invalidate];
    [_stateTimer invalidate];
    [self detachCurrentItem];
}

#pragma mark - Validation

+ (NSString *)validateSettings:(NSDictionary *)s {
    if (![s isKindOfClass:[NSDictionary class]]) return @"settings: expected an object";
    NSArray *steps = s[@"steps"];
    if (![steps isKindOfClass:[NSArray class]] || steps.count == 0) return @"settings.steps: expected a non-empty array";
    NSSet *allowed = [NSSet setWithObjects:@"vocab", @"clear", @"translation", @"original", nil];
    NSMutableSet *seen = [NSMutableSet set];
    for (id step in steps) {
        if (![step isKindOfClass:[NSString class]] || ![allowed containsObject:step]) {
            return [NSString stringWithFormat:@"settings.steps: unknown step %@", step];
        }
        if ([seen containsObject:step]) return [NSString stringWithFormat:@"settings.steps: duplicate step %@", step];
        [seen addObject:step];
    }
    if (![s[@"autoAdvance"] isKindOfClass:[NSNumber class]]) return @"settings.autoAdvance: expected a bool";
    NSNumber *rate = s[@"rate"];
    if (![rate isKindOfClass:[NSNumber class]] || rate.doubleValue < 0.5 || rate.doubleValue > 1.5) {
        return @"settings.rate: expected a number in 0.5...1.5";
    }
    NSNumber *englishRate = s[@"englishRate"];
    if (![englishRate isKindOfClass:[NSNumber class]] || englishRate.doubleValue < 0.5 || englishRate.doubleValue > 1.5) {
        return @"settings.englishRate: expected a number in 0.5...1.5";
    }
    NSNumber *repeat = s[@"repeatOriginal"];
    if (![repeat isKindOfClass:[NSNumber class]] || repeat.integerValue < 1 || repeat.integerValue > 3) {
        return @"settings.repeatOriginal: expected an int in 1...3";
    }
    NSString *pocket = s[@"pocketDoublePress"];
    if (![pocket isKindOfClass:[NSString class]] || !([pocket isEqual:@"voice"] || [pocket isEqual:@"next"])) {
        return @"settings.pocketDoublePress: expected \"voice\" or \"next\"";
    }
    NSNumber *slow = s[@"pocketReplaySlowdown"];
    if (![slow isKindOfClass:[NSNumber class]] || slow.integerValue < 0 || slow.integerValue > 50) {
        return @"settings.pocketReplaySlowdown: expected an int percent in 0...50";
    }
    return nil;
}

static NSString *ListenValidateSections(NSArray *sections) {
    if (![sections isKindOfClass:[NSArray class]] || sections.count == 0) return @"sections: expected a non-empty array";
    for (NSUInteger i = 0; i < sections.count; i++) {
        NSDictionary *sec = sections[i];
        if (![sec isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"sections[%lu]: expected an object", (unsigned long)i];
        NSNumber *start = sec[@"start"], *end = sec[@"end"];
        if (![start isKindOfClass:[NSNumber class]] || ![end isKindOfClass:[NSNumber class]] ||
            end.doubleValue <= start.doubleValue || start.doubleValue < 0) {
            return [NSString stringWithFormat:@"sections[%lu]: start/end must be numbers with end > start >= 0", (unsigned long)i];
        }
        NSDictionary *audio = sec[@"audio"];
        if (![audio isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"sections[%lu].audio: expected an object", (unsigned long)i];
        for (NSString *key in @[@"original", @"clear", @"translation"]) {
            NSString *url = audio[key];
            if (![url isKindOfClass:[NSString class]] || [NSURL URLWithString:url] == nil) {
                return [NSString stringWithFormat:@"sections[%lu].audio.%@: expected a URL string, got %@", (unsigned long)i, key, url];
            }
        }
        id vocab = audio[@"vocab"];
        if (vocab != nil && ![vocab isKindOfClass:[NSNull class]] &&
            !([vocab isKindOfClass:[NSString class]] && [NSURL URLWithString:vocab] != nil)) {
            return [NSString stringWithFormat:@"sections[%lu].audio.vocab: expected a URL string or null", (unsigned long)i];
        }
    }
    return nil;
}

#pragma mark - Accessors

- (BOOL)playing { return _playing || _replayKind != nil; }
- (BOOL)hasItem { return _sections != nil; }
- (NSInteger)currentIdx { return _idx; }
- (NSInteger)sectionCount { return (NSInteger)_sections.count; }
- (NSDictionary *)settings { return _settings ?: @{}; }

- (BOOL)audioWanted { return _playing || _replayKind != nil; }

- (NSArray<NSString *> *)effectiveStepsForIdx:(NSInteger)idx {
    NSDictionary *audio = _sections[idx][@"audio"];
    BOOL hasVocab = [audio[@"vocab"] isKindOfClass:[NSString class]];
    NSMutableArray *steps = [NSMutableArray array];
    for (NSString *step in _settings[@"steps"]) {
        if ([step isEqual:@"vocab"] && !hasVocab) continue;
        [steps addObject:step];
    }
    return steps;
}

- (NSURL *)urlForKind:(NSString *)kind idx:(NSInteger)idx {
    id value = _sections[idx][@"audio"][kind];
    return [value isKindOfClass:[NSString class]] ? [NSURL URLWithString:value] : nil;
}

#pragma mark - Public API

- (NSString *)loadItemId:(NSString *)itemId
                   title:(NSString *)title
                sections:(NSArray<NSDictionary *> *)sections
                settings:(NSDictionary *)settings
                startIdx:(NSInteger)startIdx {
    NSString *error = ListenValidateSections(sections) ?: [ListenPlayer validateSettings:settings];
    if (error) return error;
    if (startIdx < 0 || startIdx >= (NSInteger)sections.count) {
        return [NSString stringWithFormat:@"startIdx %ld out of range 0..%lu", (long)startIdx, (unsigned long)sections.count - 1];
    }
    [self stopEverything];
    [_assets removeAllObjects];
    _itemId = [itemId copy];
    _title = [title copy];
    _sections = [sections copy];
    _settings = [settings copy];
    _idx = startIdx;
    _stepIdx = 0;
    _repeatDone = 0;
    _finished = NO;
    _lastError = nil;
    [self prefetch];
    [self publish];
    return nil;
}

- (NSString *)setSettings:(NSDictionary *)settings {
    NSString *error = [ListenPlayer validateSettings:settings];
    if (error) return error;
    _settings = [settings copy];
    if (_sections) {
        NSInteger count = (NSInteger)[self effectiveStepsForIdx:_idx].count;
        if (_stepIdx >= count) _stepIdx = MAX(0, count - 1);
        if (_currentItem && ([_clipKind isEqual:@"original"] || [_clipKind isEqual:@"translation"]) && !_clipEnded) {
            _clipRate = [self rateForKind:_clipKind];
            _player.defaultRate = (float)_clipRate;
            if (_player.rate > 0) _player.rate = (float)_clipRate;
        }
        [self prefetch];
    }
    [self publish];
    return nil;
}

- (NSString *)adjustRateBy:(double)delta {
    if (!_settings) return @"no item loaded";
    double rate = [_settings[@"rate"] doubleValue] + delta;
    rate = MIN(1.5, MAX(0.5, round(rate * 10.0) / 10.0));
    NSMutableDictionary *s = [_settings mutableCopy];
    s[@"rate"] = @(rate);
    return [self setSettings:s];
}

- (NSString *)play {
    if (!_sections) return @"no item loaded";
    NSString *error = [self activateSession];
    if (error) { [self reportError:error]; return error; }
    _lastError = nil;
    [self registerRemoteCommandsIfNeeded];
    _playing = YES;
    if (_finished) {
        _finished = NO;
        _stepIdx = 0;
        _repeatDone = 0;
        [self startCurrentStep];
    } else if (_currentItem && !_clipEnded) {
        // Resume a paused clip. If it is still loading, its status handler starts it.
        if (_clipReady) [self beginAudio];
    } else if (_gapTimer == nil) {
        [self startCurrentStep];
    }
    [self publish];
    return nil;
}

- (NSString *)pause {
    if (!_sections) return @"no item loaded";
    [self pauseDeactivatingSession:YES];
    return nil;
}

- (NSString *)toggle {
    return self.playing ? [self pause] : [self play];
}

- (NSString *)next {
    if (!_sections) return @"no item loaded";
    if (_idx + 1 >= (NSInteger)_sections.count) return nil;
    [self moveToIdx:_idx + 1];
    return nil;
}

- (NSString *)prev {
    if (!_sections) return @"no item loaded";
    [self moveToIdx:MAX(0, _idx - 1)];
    return nil;
}

- (NSString *)gotoIdx:(NSInteger)idx {
    if (!_sections) return @"no item loaded";
    if (idx < 0 || idx >= (NSInteger)_sections.count) {
        return [NSString stringWithFormat:@"goto: idx %ld out of range 0..%lu", (long)idx, (unsigned long)_sections.count - 1];
    }
    [self moveToIdx:idx];
    return nil;
}

- (NSString *)replay:(NSString *)kind {
    return [self replay:kind slowdown:0 then:nil];
}

- (NSString *)replay:(NSString *)kind slowdown:(double)slowdown then:(NSString *)then {
    if (!_sections) return @"no item loaded";
    for (NSString *k in then ? @[kind, then] : @[kind]) {
        if (![@[@"original", @"clear", @"translation", @"vocab"] containsObject:k]) {
            return [NSString stringWithFormat:@"replay: unknown kind %@", k];
        }
        if (![self urlForKind:k idx:_idx]) return [NSString stringWithFormat:@"replay: section %ld has no %@ clip", (long)_idx, k];
    }
    NSString *error = [self activateSession];
    if (error) { [self reportError:error]; return error; }
    [self registerRemoteCommandsIfNeeded];
    if (_replayKind == nil) {
        _resumeAfterReplay = _playing;
    }
    _playing = NO;
    _replayKind = [kind copy];
    _replayThen = [then copy];
    _replaySlowdown = slowdown;
    [self startClipKind:kind];
    [self publish];
    return nil;
}

- (NSString *)replayOriginalSlowed {
    return [self replay:@"original" slowdown:[_settings[@"pocketReplaySlowdown"] doubleValue] / 100.0 then:nil];
}

- (NSString *)replayTranslationThenOriginal {
    return [self replay:@"translation" slowdown:0 then:@"original"];
}

/// `original` plays at settings.rate (see -originalClipRate), `translation` at settings.englishRate, the rest at 1.
- (double)rateForKind:(NSString *)kind {
    if ([kind isEqual:@"original"]) return [self originalClipRate];
    if ([kind isEqual:@"translation"]) return [_settings[@"englishRate"] doubleValue];
    return 1.0;
}

/// settings.rate, minus the pocket-replay slowdown while an `original` replay is in flight.
- (double)originalClipRate {
    double rate = [_settings[@"rate"] doubleValue];
    return _replayKind ? rate * (1.0 - _replaySlowdown) : rate;
}

#pragma mark - Loop

- (void)moveToIdx:(NSInteger)idx {
    [self cancelGap];
    _replayKind = nil;
    _replayThen = nil;
    _resumeAfterReplay = NO;
    [self discardCurrentItem];
    _idx = idx;
    _stepIdx = 0;
    _repeatDone = 0;
    _finished = NO;
    if (_playing) {
        [self startCurrentStep];
    }
    [self prefetch];
    [self publish];
}

- (void)startCurrentStep {
    NSArray<NSString *> *steps = [self effectiveStepsForIdx:_idx];
    if (steps.count == 0) {
        _playing = NO;
        [self reportError:[NSString stringWithFormat:@"section %ld has no playable steps for settings.steps", (long)_idx]];
        return;
    }
    [self startClipKind:steps[MIN(_stepIdx, (NSInteger)steps.count - 1)]];
}

/// Advances (idx, stepIdx, repeat) one clip, per the protocol's step loop.
/// Returns NO when the loop is over (no autoAdvance, or past the last section).
- (BOOL)advanceIdx:(NSInteger *)idx step:(NSInteger *)stepIdx repeat:(NSInteger *)repeat {
    NSArray<NSString *> *steps = [self effectiveStepsForIdx:*idx];
    NSString *step = steps[MIN(*stepIdx, (NSInteger)steps.count - 1)];
    if ([step isEqual:@"original"] && *repeat + 1 < [_settings[@"repeatOriginal"] integerValue]) {
        *repeat += 1;
        return YES;
    }
    *repeat = 0;
    *stepIdx += 1;
    if (*stepIdx < (NSInteger)steps.count) return YES;
    if ([_settings[@"autoAdvance"] boolValue] && *idx + 1 < (NSInteger)_sections.count) {
        *idx += 1;
        *stepIdx = 0;
        return YES;
    }
    return NO;
}

- (void)clipDidEnd {
    _clipEnded = YES;
    if (_replayKind && _replayThen) {
        _replayKind = _replayThen;
        _replayThen = nil;
        _replaySlowdown = 0;
        [self startClipKind:_replayKind];
        [self publish];
        return;
    }
    if (_replayKind) {
        _replayKind = nil;
        if (_resumeAfterReplay) {
            _resumeAfterReplay = NO;
            _playing = YES;
            _repeatDone = 0;
            [self scheduleNextStep];
        } else {
            [self pauseDeactivatingSession:YES];
        }
        [self publish];
        return;
    }
    NSInteger idx = _idx, step = _stepIdx, repeat = _repeatDone;
    if ([self advanceIdx:&idx step:&step repeat:&repeat]) {
        _idx = idx; _stepIdx = step; _repeatDone = repeat;
        [self scheduleNextStep];
    } else {
        _finished = YES;
        [self pauseDeactivatingSession:YES];
    }
    [self publish];
}

- (void)scheduleNextStep {
    [self cancelGap];
    __weak typeof(self) weakSelf = self;
    _gapTimer = [NSTimer scheduledTimerWithTimeInterval:kListenGapSeconds repeats:NO block:^(NSTimer *timer) {
        ListenPlayer *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_gapTimer = nil;
        [strongSelf startCurrentStep];
        [strongSelf publish];
    }];
    [self prefetch];
}

- (void)cancelGap {
    [_gapTimer invalidate];
    _gapTimer = nil;
}

- (void)pauseDeactivatingSession:(BOOL)deactivate {
    [self cancelGap];
    if (_replayKind) {
        // A replay interrupted by pause is discarded; play restarts the step.
        _replayKind = nil;
        _replayThen = nil;
        _resumeAfterReplay = NO;
        _clipEnded = YES;
    }
    _playing = NO;
    [_player pause];
    [self stopStateTimer];
    if (deactivate) [self deactivateSession];
    [self publish];
}

- (void)stopEverything {
    [self cancelGap];
    _replayKind = nil;
    _replayThen = nil;
    _resumeAfterReplay = NO;
    _playing = NO;
    [self discardCurrentItem];
    [self stopStateTimer];
    [self deactivateSession];
}

#pragma mark - Clips

- (AVURLAsset *)assetForURL:(NSURL *)url {
    AVURLAsset *asset = _assets[url];
    if (!asset) {
        asset = [AVURLAsset URLAssetWithURL:url options:nil];
        _assets[url] = asset;
    }
    return asset;
}

/// Warms the assets of the next clips so the gap between them is the 0.4 s
/// timer, not a network round trip.
- (void)prefetch {
    if (!_sections || !_settings) return;
    NSInteger idx = _idx, step = _stepIdx, repeat = _repeatDone;
    for (NSInteger i = 0; i < kListenPrefetchCount; i++) {
        if (![self advanceIdx:&idx step:&step repeat:&repeat]) return;
        NSArray<NSString *> *steps = [self effectiveStepsForIdx:idx];
        NSURL *url = [self urlForKind:steps[MIN(step, (NSInteger)steps.count - 1)] idx:idx];
        if (!url) continue;
        AVURLAsset *asset = [self assetForURL:url];
        [asset loadValuesAsynchronouslyForKeys:@[@"playable", @"duration"] completionHandler:nil];
    }
}

- (void)startClipKind:(NSString *)kind {
    [self cancelGap];
    [self discardCurrentItem];
    NSURL *url = [self urlForKind:kind idx:_idx];
    if (!url) {
        _playing = NO;
        _replayKind = nil;
        [self reportError:[NSString stringWithFormat:@"section %ld has no %@ clip", (long)_idx, kind]];
        return;
    }
    BOOL isOriginal = [kind isEqual:@"original"];
    NSDictionary *section = _sections[_idx];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:[self assetForURL:url]];
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
    _clipKind = [kind copy];
    _clipStart = isOriginal ? [section[@"start"] doubleValue] : 0;
    _clipEnd = isOriginal ? [section[@"end"] doubleValue] : 0;
    _clipRate = [self rateForKind:kind];
    _clipReady = NO;
    _clipEnded = NO;
    if (isOriginal) item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(_clipEnd, 1000);
    _currentItem = item;

    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    id endToken = [nc addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue]
                              usingBlock:^(NSNotification *note) {
        ListenPlayer *strongSelf = weakSelf;
        if (strongSelf && note.object == strongSelf->_currentItem) [strongSelf clipDidEnd];
    }];
    id failToken = [nc addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue]
                               usingBlock:^(NSNotification *note) {
        ListenPlayer *strongSelf = weakSelf;
        if (!strongSelf || note.object != strongSelf->_currentItem) return;
        NSError *err = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
        [strongSelf failCurrentClipWithError:err prefix:@"failed to play to end"];
    }];
    _itemObservers = @[endToken, failToken];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:ListenItemStatusContext];

    [_player pause];
    [_player removeAllItems];
    [_player insertItem:item afterItem:nil];
    _player.defaultRate = (float)_clipRate;
    [self prefetch];
}

- (void)detachCurrentItem {
    if (!_currentItem) return;
    [_currentItem removeObserver:self forKeyPath:@"status" context:ListenItemStatusContext];
    for (id token in _itemObservers) [[NSNotificationCenter defaultCenter] removeObserver:token];
    _itemObservers = nil;
    _currentItem = nil;
}

- (void)discardCurrentItem {
    [_player pause];
    [self detachCurrentItem];
    [_player removeAllItems];
    _clipReady = NO;
    _clipEnded = YES;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ListenItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayerItem *item = object;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (item != self->_currentItem) return;
        [self itemStatusChanged:item];
    });
}

- (void)itemStatusChanged:(AVPlayerItem *)item {
    if (item.status == AVPlayerItemStatusFailed) {
        [self failCurrentClipWithError:item.error prefix:@"failed to load"];
        return;
    }
    if (item.status != AVPlayerItemStatusReadyToPlay || _clipReady) return;
    __weak typeof(self) weakSelf = self;
    void (^ready)(BOOL) = ^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ListenPlayer *strongSelf = weakSelf;
            if (!strongSelf || item != strongSelf->_currentItem || !finished) return;
            strongSelf->_clipReady = YES;
            if ([strongSelf audioWanted]) [strongSelf beginAudio];
            [strongSelf publish];
        });
    };
    if (_clipStart > 0) {
        [item seekToTime:CMTimeMakeWithSeconds(_clipStart, 1000)
         toleranceBefore:kCMTimeZero
          toleranceAfter:kCMTimeZero
       completionHandler:ready];
    } else {
        ready(YES);
    }
}

- (void)failCurrentClipWithError:(NSError *)error prefix:(NSString *)prefix {
    NSURL *url = [(AVURLAsset *)_currentItem.asset URL];
    NSString *message = [NSString stringWithFormat:@"%@ clip %@ (section %ld) %@: %@ [%@ %ld]",
                         _clipKind, url.absoluteString, (long)_idx, prefix,
                         error.localizedDescription, error.domain, (long)error.code];
    [self pauseDeactivatingSession:YES];
    [self reportError:message];
}

- (void)beginAudio {
    _player.defaultRate = (float)_clipRate;
    [_player play];
    [self startStateTimer];
}

#pragma mark - Audio session

- (NSString *)activateSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeSpokenAudio options:0 error:&error] ||
        ![session setActive:YES error:&error]) {
        return [NSString stringWithFormat:@"audio session activate failed: %@ [%@ %ld]",
                error.localizedDescription, error.domain, (long)error.code];
    }
    return nil;
}

- (void)deactivateSession {
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setActive:NO
                                        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                              error:&error]) {
        // Same stance as GLWebBridge's voiceStop: the pause itself succeeded, so
        // a failed teardown is logged, not raised at the page.
        GLLog(@"audio session deactivate failed: %@ [%@ %ld]", error.localizedDescription, error.domain, (long)error.code);
    }
}

- (void)audioSessionInterruption:(NSNotification *)note {
    AVAudioSessionInterruptionType type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        GLLog(@"interruption began (playing=%d)", self.playing);
        _resumeAfterInterruption = self.playing;
        if (self.playing) [self pauseDeactivatingSession:NO];
    } else {
        AVAudioSessionInterruptionOptions options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        GLLog(@"interruption ended (shouldResume=%d wasPlaying=%d)",
              (options & AVAudioSessionInterruptionOptionShouldResume) != 0, _resumeAfterInterruption);
        BOOL resume = _resumeAfterInterruption && (options & AVAudioSessionInterruptionOptionShouldResume);
        _resumeAfterInterruption = NO;
        if (resume) [self play];
    }
}

- (void)audioRouteChanged:(NSNotification *)note {
    AVAudioSessionRouteChangeReason reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    GLLog(@"route change reason=%lu playing=%d", (unsigned long)reason, self.playing);
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable && self.playing) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self pauseDeactivatingSession:YES]; });
    }
}

#pragma mark - State

- (void)startStateTimer {
    if (_stateTimer) return;
    __weak typeof(self) weakSelf = self;
    _stateTimer = [NSTimer scheduledTimerWithTimeInterval:kListenStateTickSeconds repeats:YES block:^(NSTimer *timer) {
        ListenPlayer *strongSelf = weakSelf;
        if (strongSelf.stateChanged) strongSelf.stateChanged();
    }];
}

- (void)stopStateTimer {
    [_stateTimer invalidate];
    _stateTimer = nil;
}

static double ListenFinite(double v) { return isfinite(v) ? v : 0; }

- (NSString *)currentStepName {
    if (_replayKind) return _replayKind;
    if (!_sections || _finished) return nil;
    NSArray<NSString *> *steps = [self effectiveStepsForIdx:_idx];
    return steps.count ? steps[MIN(_stepIdx, (NSInteger)steps.count - 1)] : nil;
}

- (NSDictionary *)stateDictionary {
    double position = 0, duration = 0;
    if (_currentItem) {
        if ([_clipKind isEqual:@"original"]) {
            duration = _clipEnd - _clipStart;
        } else {
            duration = ListenFinite(CMTimeGetSeconds(_currentItem.duration));
        }
        position = _clipEnded ? duration
                              : MIN(duration, MAX(0, ListenFinite(CMTimeGetSeconds(_player.currentTime)) - _clipStart));
    }
    NSString *step = [self currentStepName];
    return @{
        @"itemId": _itemId ?: [NSNull null],
        @"idx": @(_idx),
        @"step": step ?: [NSNull null],
        @"stepIndex": @(_stepIdx),
        @"stepCount": @(_sections ? [self effectiveStepsForIdx:_idx].count : 0),
        @"playing": @(self.playing),
        @"position": @(position),
        @"duration": @(duration),
        @"error": _lastError ?: [NSNull null],
    };
}

- (void)reportError:(NSString *)message {
    GLLog(@"error: %@", message);
    _lastError = [message copy];
    if (self.errorReported) self.errorReported(message);
    [self publish];
}

- (void)publish {
    [self updateNowPlaying];
    if (self.stateChanged) self.stateChanged();
}

#pragma mark - Now Playing / remote commands

static NSString *ListenStepLabel(NSString *step) {
    NSDictionary *labels = @{@"vocab": @"Vocab", @"clear": @"Clear", @"translation": @"English", @"original": @"Original"};
    return labels[step] ?: @"Listen";
}

- (void)updateNowPlaying {
    if (!_sections) {
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        return;
    }
    NSDictionary *state = [self stateDictionary];
    NSString *step = [self currentStepName];
    NSString *title = [NSString stringWithFormat:@"%@ · %ld/%lu",
                       step ? ListenStepLabel(step) : @"Done", (long)_idx + 1, (unsigned long)_sections.count];
    BOOL sounding = self.playing && _clipReady && !_clipEnded;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyArtist: _title ?: @"",
        MPMediaItemPropertyAlbumTitle: @"Listen",
        MPMediaItemPropertyPlaybackDuration: state[@"duration"],
        MPNowPlayingInfoPropertyElapsedPlaybackTime: state[@"position"],
        MPNowPlayingInfoPropertyPlaybackRate: @(sounding ? _clipRate : 0.0),
        MPNowPlayingInfoPropertyDefaultPlaybackRate: @(1.0),
    };
}

- (void)registerRemoteCommandsIfNeeded {
    if (_remoteCommandsRegistered) return;
    _remoteCommandsRegistered = YES;
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    __weak typeof(self) weakSelf = self;

    center.togglePlayPauseCommand.enabled = YES;
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf reportIfError:[weakSelf toggle]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    // AirPods and the lock screen send pause/play rather than toggle while
    // pause/play are available, so all three must be live.
    center.pauseCommand.enabled = YES;
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        ListenPlayer *strongSelf = weakSelf;
        if (strongSelf.playing) [strongSelf reportIfError:[strongSelf pause]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    center.playCommand.enabled = YES;
    [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        ListenPlayer *strongSelf = weakSelf;
        if (!strongSelf.playing) [strongSelf reportIfError:[strongSelf play]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    center.nextTrackCommand.enabled = YES;
    [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        ListenPlayer *strongSelf = weakSelf;
        if (strongSelf.nextTrackOverride && strongSelf.nextTrackOverride()) return MPRemoteCommandHandlerStatusSuccess;
        [strongSelf reportIfError:[strongSelf next]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    center.previousTrackCommand.enabled = YES;
    [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf reportIfError:[weakSelf replay:@"original"]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    center.skipForwardCommand.enabled = YES;
    center.skipForwardCommand.preferredIntervals = @[@15];
    [center.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf reportIfError:[weakSelf next]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    center.skipBackwardCommand.enabled = YES;
    center.skipBackwardCommand.preferredIntervals = @[@15];
    [center.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf reportIfError:[weakSelf replay:@"original"]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.stopCommand.enabled = NO;
    center.seekForwardCommand.enabled = NO;
    center.seekBackwardCommand.enabled = NO;
    center.changePlaybackPositionCommand.enabled = NO;
    center.changePlaybackRateCommand.enabled = NO;
    GLLog(@"remote commands registered (pause=%d play=%d toggle=%d)", center.pauseCommand.enabled,
          center.playCommand.enabled, center.togglePlayPauseCommand.enabled);
}

- (void)reportIfError:(NSString *)error {
    if (error) [self reportError:error];
}

@end
