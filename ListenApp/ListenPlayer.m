#import "ListenPlayer.h"

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

#import "GLLog.h"
#import "ListenDownloads.h"
#import "ListenRewind.h"

static NSTimeInterval const kListenGapSeconds = 0.4;
static NSTimeInterval const kListenStateTickSeconds = 0.25;
static NSInteger const kListenPrefetchCount = 2;
static void *ListenItemStatusContext = &ListenItemStatusContext;

// The vocab step is spoken by the device voices (AVSpeechSynthesizer) inside this same queue, not played from an mp3: it
// needs no network or Azure clip, and AVSpeechSynthesizer keeps speaking with the screen locked, which JS speechSynthesis in
// the WKWebView does not.
@interface ListenPlayer () <AVSpeechSynthesizerDelegate>
@end

@implementation ListenPlayer {
    AVQueuePlayer *_player;
    AVSpeechSynthesizer *_speech;
    AVSpeechUtterance *_speechLast; // last utterance of the vocab clip in flight; nil = no vocab clip speaking
    NSMutableDictionary<NSURL *, AVURLAsset *> *_assets;

    // Loaded item.
    NSString *_itemId;
    NSString *_title;
    NSURL *_artworkURL;
    MPMediaItemArtwork *_artwork; // nil until _artworkURL's picture arrives (or when the item has none)
    NSArray<NSDictionary *> *_sections;
    NSDictionary *_settings;

    // Loop position.
    NSInteger _idx;
    NSInteger _stepIdx;      // index into -effectiveStepsForIdx:_idx
    NSInteger _repeatDone;   // completed repeats of the current step (settings.times)
    BOOL _finished;          // section ended without autoAdvance; step is null
    BOOL _playing;           // the loop wants audio
    NSString *_replayKind;   // one-off replay clip in flight
    BOOL _resumeAfterReplay;
    NSMutableArray<NSString *> *_replayQueue; // clip kinds still to play after the current replay clip
    BOOL _replayAdvance;     // the replay in flight was started with after:"advance"
    BOOL _loop;              // session-only: repeat the current section's original, never advance
    BOOL _loopRun;           // the current section run started with loop on (stays set when loop is turned off mid-clip)
    BOOL _hasLoopRange;      // loop repeats only [_loopRangeStart, _loopRangeEnd] of the current section's original (word loop)
    double _loopRangeStart;  // absolute episode seconds, already clamped to the section
    double _loopRangeEnd;
    BOOL _hasContinue;       // a range loop was turned off between passes: the next original plays from _continueStart to the section end
    double _continueStart;
    NSInteger _furthest;     // highest section idx entered this session
    id _chainObserver;       // periodic time observer watching for the chained section boundary
    NSInteger _chainNextIdx; // continuous mode: section the in-flight original clip flows into (-1 = none)
    double _replaySlowdown;  // fraction slower than settings.rate for every `original` clip of the current replay

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
        _speech = [[AVSpeechSynthesizer alloc] init];
        _speech.delegate = self;
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        _chainNextIdx = -1;
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
    [self cancelSpeech];
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
    if (s[@"clearRate"] != nil) {
        NSNumber *clearRate = s[@"clearRate"];
        if (![clearRate isKindOfClass:[NSNumber class]] || clearRate.doubleValue < 0.5 || clearRate.doubleValue > 1.5) {
            return @"settings.clearRate: expected a number in 0.5...1.5";
        }
    }
    if (s[@"times"] != nil) {
        NSDictionary *times = s[@"times"];
        if (![times isKindOfClass:[NSDictionary class]]) return @"settings.times: expected an object";
        for (NSString *kind in times) {
            NSNumber *n = times[kind];
            if (!([kind isEqual:@"vocab"] || [kind isEqual:@"clear"] || [kind isEqual:@"translation"] || [kind isEqual:@"original"])) {
                return [NSString stringWithFormat:@"settings.times: unknown step %@", kind];
            }
            if (![n isKindOfClass:[NSNumber class]] || n.integerValue < 1 || n.integerValue > 3) {
                return [NSString stringWithFormat:@"settings.times.%@: expected an int in 1...3", kind];
            }
        }
    }
    NSString *pocket = s[@"pocketDoublePress"];
    if (![pocket isKindOfClass:[NSString class]] || !([pocket isEqual:@"voice"] || [pocket isEqual:@"next"])) {
        return @"settings.pocketDoublePress: expected \"voice\" or \"next\"";
    }
    NSNumber *slow = s[@"pocketReplaySlowdown"];
    if (![slow isKindOfClass:[NSNumber class]] || slow.integerValue < 0 || slow.integerValue > 50) {
        return @"settings.pocketReplaySlowdown: expected an int percent in 0...50";
    }
    if (s[@"revisitSteps"] != nil) {
        NSString *revisit = s[@"revisitSteps"];
        if (![revisit isKindOfClass:[NSString class]] || !([revisit isEqual:@"original"] || [revisit isEqual:@"all"])) {
            return @"settings.revisitSteps: expected \"original\" or \"all\"";
        }
    }
    for (NSString *flag in @[@"skipRepeats", @"continuous"]) {
        if (s[flag] != nil && ![s[flag] isKindOfClass:[NSNumber class]]) {
            return [NSString stringWithFormat:@"settings.%@: expected a bool", flag];
        }
    }
    if (s[@"holdAfter"] != nil) {
        NSArray *hold = s[@"holdAfter"];
        if (![hold isKindOfClass:[NSArray class]]) return @"settings.holdAfter: expected an array";
        for (id i in hold) {
            if (![i isKindOfClass:[NSNumber class]] || [i doubleValue] != (double)[i integerValue] || [i integerValue] < 0) {
                return [NSString stringWithFormat:@"settings.holdAfter: expected non-negative ints, got %@", i];
            }
        }
    }
    if (s[@"speakStops"] != nil) {
        NSArray *stops = s[@"speakStops"];
        if (![stops isKindOfClass:[NSArray class]]) return @"settings.speakStops: expected an array";
        for (id stop in stops) {
            if (![stop isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"settings.speakStops: expected objects, got %@", stop];
            NSString *kind = stop[@"kind"];
            if (![kind isKindOfClass:[NSString class]] || !([kind isEqual:@"repeat"] || [kind isEqual:@"summary"])) {
                return [NSString stringWithFormat:@"settings.speakStops: kind must be \"repeat\" or \"summary\", got %@", kind];
            }
            for (NSString *key in @[@"afterIdx", @"from", @"to"]) {
                id i = stop[key];
                if (![i isKindOfClass:[NSNumber class]] || [i doubleValue] != (double)[i integerValue] || [i integerValue] < 0) {
                    return [NSString stringWithFormat:@"settings.speakStops.%@: expected a non-negative int, got %@", key, i];
                }
            }
            if ([stop[@"from"] integerValue] > [stop[@"to"] integerValue]) {
                return [NSString stringWithFormat:@"settings.speakStops: from %@ is after to %@", stop[@"from"], stop[@"to"]];
            }
        }
    }
    if (s[@"rewinds"] != nil) {
        NSString *error = [ListenRewind validatePresets:s[@"rewinds"]];
        if (error) return error;
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
        if (sec[@"repeat"] != nil && ![sec[@"repeat"] isKindOfClass:[NSNumber class]]) {
            return [NSString stringWithFormat:@"sections[%lu].repeat: expected a bool", (unsigned long)i];
        }
        // audio.vocab is null (no vocab step for this section), the two locales the device voices speak in (the words
        // themselves are the section's `vocab` list), or a vocab mp3 URL: the shape servers sent before device speech,
        // still played so this build works against either server during the rollout.
        id vocab = audio[@"vocab"];
        if ([vocab isKindOfClass:[NSString class]]) {
            if ([NSURL URLWithString:vocab] == nil) {
                return [NSString stringWithFormat:@"sections[%lu].audio.vocab: not a URL", (unsigned long)i];
            }
        } else if (vocab != nil && ![vocab isKindOfClass:[NSNull class]]) {
            if (![vocab isKindOfClass:[NSDictionary class]] ||
                ![vocab[@"target"] isKindOfClass:[NSString class]] || ![vocab[@"native"] isKindOfClass:[NSString class]] ||
                [AVSpeechSynthesisVoice voiceWithLanguage:vocab[@"target"]] == nil ||
                [AVSpeechSynthesisVoice voiceWithLanguage:vocab[@"native"]] == nil) {
                return [NSString stringWithFormat:@"sections[%lu].audio.vocab: expected null or {target, native} locales with an installed voice each", (unsigned long)i];
            }
            NSArray *terms = sec[@"vocab"];
            if (![terms isKindOfClass:[NSArray class]] || terms.count == 0) {
                return [NSString stringWithFormat:@"sections[%lu].vocab: expected a non-empty array when audio.vocab is set", (unsigned long)i];
            }
            for (NSDictionary *t in terms) {
                if (![t isKindOfClass:[NSDictionary class]] || ![t[@"term"] isKindOfClass:[NSString class]] || ![t[@"gloss"] isKindOfClass:[NSString class]]) {
                    return [NSString stringWithFormat:@"sections[%lu].vocab: every entry needs string term and gloss", (unsigned long)i];
                }
            }
        }
    }
    return nil;
}

#pragma mark - Accessors

- (BOOL)playing { return _playing || _replayKind != nil; }
- (BOOL)hasItem { return _sections != nil; }
- (NSInteger)currentIdx { return _idx; }
- (NSString *)itemId { return _itemId; }
- (NSInteger)sectionCount { return (NSInteger)_sections.count; }
- (NSDictionary *)settings { return _settings ?: @{}; }

- (BOOL)audioWanted { return _playing || _replayKind != nil; }

/// A section before the furthest one entered plays only its original, once, unless settings.revisitSteps is "all" (absent = "original").
- (BOOL)isRevisitIdx:(NSInteger)idx {
    NSString *mode = _settings[@"revisitSteps"] ?: @"original";
    return idx < _furthest && [mode isEqual:@"original"];
}

/// settings.skipRepeats: a section marked `repeat` plays only its original, once (when "original" is among settings.steps).
- (BOOL)isSkippedRepeatIdx:(NSInteger)idx {
    return [_settings[@"skipRepeats"] boolValue] && [_sections[idx][@"repeat"] boolValue] &&
           [_settings[@"steps"] containsObject:@"original"];
}

/// Revisited or skipped-repeat sections play only their original, exactly once. settings.continuous (songs) does so for
/// every section, ignoring steps/times/revisitSteps/skipRepeats.
- (BOOL)playsOriginalOnceIdx:(NSInteger)idx {
    return [self continuous] || [self isRevisitIdx:idx] || [self isSkippedRepeatIdx:idx];
}

- (BOOL)continuous { return [_settings[@"continuous"] boolValue]; }

- (void)enterIdx:(NSInteger)idx {
    _idx = idx;
    _furthest = MAX(_furthest, idx);
    _hasLoopRange = NO; // a word's span means nothing in another section
    _hasContinue = NO;
}

- (NSArray<NSString *> *)effectiveStepsForIdx:(NSInteger)idx {
    if (_loop || [self playsOriginalOnceIdx:idx]) return @[@"original"];
    NSDictionary *audio = _sections[idx][@"audio"];
    BOOL hasVocab = [audio[@"vocab"] isKindOfClass:[NSDictionary class]] || [audio[@"vocab"] isKindOfClass:[NSString class]];
    NSMutableArray *steps = [NSMutableArray array];
    for (NSString *step in _settings[@"steps"]) {
        if ([step isEqual:@"vocab"] && !hasVocab) continue;
        [steps addObject:step];
    }
    return steps;
}

- (NSURL *)urlForKind:(NSString *)kind idx:(NSInteger)idx {
    id value = _sections[idx][@"audio"][kind];
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSURL *remote = [NSURL URLWithString:value];
    if (!remote) return nil;
    // Downloaded copy (ListenDownloads) wins so the clip plays offline.
    NSURL *local = [ListenDownloads localURLForRemote:remote];
    return local ?: remote;
}

#pragma mark - Public API

- (NSString *)loadItemId:(NSString *)itemId
                   title:(NSString *)title
                 artwork:(NSURL *)artwork
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
    [self fetchArtwork:artwork];
    _sections = [sections copy];
    _settings = [settings copy];
    _idx = startIdx;
    _furthest = startIdx;
    _loop = NO;
    _loopRun = NO;
    _hasLoopRange = NO;
    _hasContinue = NO;
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
    if (self.speakTurnActive && self.speakTurnActive()) return @"play: a Listen & speak turn is running";
    NSString *error = [self activateSession];
    if (error) { [self reportError:error]; return error; }
    _lastError = nil;
    [self registerRemoteCommandsIfNeeded];
    _playing = YES;
    if (_finished) {
        _finished = NO;
        _stepIdx = 0;
        _repeatDone = 0;
        [self startRun];
    } else if (_currentItem && !_clipEnded) {
        // Resume a paused clip. If it is still loading, its status handler starts it.
        if (_clipReady) [self beginAudio];
    } else if (_gapTimer == nil) {
        [self startRun];
    }
    [self publish];
    return nil;
}

- (NSString *)pause {
    if (!_sections) return @"no item loaded";
    [self pausePlayback];
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
    return [self rewindSteps:@[kind] slow:0];
}

- (NSString *)rewindSteps:(NSArray<NSString *> *)steps slow:(NSInteger)slow {
    return [self rewindSteps:steps slow:slow after:@"resume"];
}

- (NSString *)rewindSteps:(NSArray<NSString *> *)steps slow:(NSInteger)slow after:(NSString *)after {
    if (!_sections) return @"no item loaded";
    if (![after isEqual:@"resume"] && ![after isEqual:@"advance"]) {
        return [NSString stringWithFormat:@"rewind: unknown rewind after \"%@\"", after];
    }
    NSString *error = [ListenRewind validateSteps:steps slow:@(slow)];
    if (error) return [@"rewind: " stringByAppendingString:error];
    NSDictionary *audio = _sections[_idx][@"audio"];
    BOOL hasVocab = [audio[@"vocab"] isKindOfClass:[NSDictionary class]] || [audio[@"vocab"] isKindOfClass:[NSString class]];
    NSArray<NSString *> *kinds = [ListenRewind playableKindsForSteps:steps hasVocab:hasVocab];
    if (kinds.count == 0) return @"rewind: no playable steps for this section";
    for (NSString *k in kinds) {
        // vocab is spoken, so it has no url to check; hasVocab above already dropped it for sections without any.
        if (!([k isEqual:@"vocab"] && [audio[@"vocab"] isKindOfClass:[NSDictionary class]]) && ![self urlForKind:k idx:_idx]) return [NSString stringWithFormat:@"rewind: section %ld has no %@ clip", (long)_idx, k];
    }
    error = [self activateSession];
    if (error) { [self reportError:error]; return error; }
    [self registerRemoteCommandsIfNeeded];
    if (_replayKind == nil) {
        _resumeAfterReplay = _playing;
    }
    _playing = NO;
    _replayAdvance = [after isEqual:@"advance"];
    _replayKind = [kinds[0] copy];
    _replayQueue = [[kinds subarrayWithRange:NSMakeRange(1, kinds.count - 1)] mutableCopy];
    _replaySlowdown = slow / 100.0;
    [self startClipKind:_replayKind];
    [self publish];
    return nil;
}

- (NSString *)setLoop:(BOOL)on rangeStart:(NSNumber *)rangeStart rangeEnd:(NSNumber *)rangeEnd {
    if (!_sections) return @"no item loaded";
    BOOL hasRange = rangeStart != nil;
    double start = 0, end = 0;
    if (hasRange) {
        if (!on) return @"loop range needs on:true";
        NSDictionary *section = _sections[_idx];
        start = MAX(rangeStart.doubleValue, [section[@"start"] doubleValue]);
        end = MIN(rangeEnd.doubleValue, [section[@"end"] doubleValue]);
        if (!(start < end)) {
            return [NSString stringWithFormat:@"loop range %g-%g is outside section %ld", rangeStart.doubleValue, rangeEnd.doubleValue, (long)_idx];
        }
    }
    BOOL sameRange = hasRange == _hasLoopRange && (!hasRange || (start == _loopRangeStart && end == _loopRangeEnd));
    if (on == _loop && sameRange) return nil;
    // Off during a range loop: no jump to the next section. The original in flight runs on to the section end; if it
    // already ended (we are in the gap), the next clip continues from the range end (same as the JS engine).
    if (!on && _hasLoopRange && _loopRun && _replayKind == nil && [_clipKind isEqual:@"original"]) {
        double sectionEnd = [_sections[_idx][@"end"] doubleValue];
        if (_currentItem && !_clipEnded && _clipEnd == _loopRangeEnd) {
            _clipEnd = sectionEnd;
            _currentItem.forwardPlaybackEndTime = CMTimeMakeWithSeconds(_clipEnd, 1000);
        } else if (_clipEnded && _loopRangeEnd < sectionEnd) {
            _hasContinue = YES;
            _continueStart = _loopRangeEnd;
        }
    }
    if (on) _hasContinue = NO;
    _loop = on;
    _hasLoopRange = hasRange;
    _loopRangeStart = start;
    _loopRangeEnd = end;
    if (on && self.playing) {
        // Interrupt whatever is sounding (clip, gap or replay) and loop the original from its start.
        [self cancelGap];
        _replayKind = nil;
        _replayQueue = nil;
        _resumeAfterReplay = NO;
        _replayAdvance = NO;
        _playing = YES;
        _stepIdx = 0;
        _repeatDone = 0;
        [self startRun];
    } else if (!self.playing && (on || _loopRun)) {
        // Paused: set the flag only. The paused clip is dropped so play starts the section fresh under the new mode.
        [self cancelGap];
        [self discardCurrentItem];
        _loopRun = NO;
        _repeatDone = 0;
        if (!on) _stepIdx = 0;
        [self prefetch];
    }
    // Off while playing: no interruption; the clip in flight finishes, then the section counts as finished.
    [self publish];
    return nil;
}

- (NSString *)rewindPreset:(NSInteger)index {
    if (!_settings) return @"no item loaded";
    NSArray<NSDictionary *> *presets = [ListenRewind presetsInSettings:_settings];
    if (index < 0 || index >= (NSInteger)presets.count) return [NSString stringWithFormat:@"rewind: preset %ld out of range", (long)index];
    return [self rewindSteps:presets[index][@"steps"] slow:[presets[index][@"slow"] integerValue]];
}

- (NSString *)replayOriginalSlowed {
    return [self rewindSteps:@[@"original"] slow:[_settings[@"pocketReplaySlowdown"] integerValue]];
}

/// `original` plays at settings.rate (see -originalClipRate), `translation` at settings.englishRate,
/// `clear` at settings.clearRate (absent = 1), the rest at 1.
- (double)rateForKind:(NSString *)kind {
    if ([kind isEqual:@"original"]) return [self originalClipRate];
    if ([kind isEqual:@"translation"]) return [_settings[@"englishRate"] doubleValue];
    if ([kind isEqual:@"clear"] && _settings[@"clearRate"]) return [_settings[@"clearRate"] doubleValue];
    return 1.0;
}

/// settings.rate, minus the replay slowdown while an `original` replay clip is in flight.
- (double)originalClipRate {
    double rate = [_settings[@"rate"] doubleValue];
    return _replayKind ? rate * (1.0 - _replaySlowdown) : rate;
}

#pragma mark - Loop

- (void)moveToIdx:(NSInteger)idx {
    [self cancelGap];
    _replayKind = nil;
    _replayQueue = nil;
    _resumeAfterReplay = NO;
    _replayAdvance = NO;
    [self discardCurrentItem];
    [self enterIdx:idx];
    _stepIdx = 0;
    _repeatDone = 0;
    _finished = NO;
    _loopRun = NO;
    if (_playing) {
        [self startRun];
    }
    [self prefetch];
    [self publish];
}

/// Begins a fresh run of the current section (the JS runFrom): loop is read here, once per run.
- (void)startRun {
    _loopRun = _loop;
    if (_loop) {
        _stepIdx = 0;
        _repeatDone = 0;
    }
    [self startCurrentStep];
}

/// Whether finishing section idx moves on to idx + 1. settings.holdAfter (Listen & speak stops) pauses after those sections
/// even with autoAdvance on. The hold lives here, not in the page, because WKWebView JS is suspended while the screen is
/// locked: a page that flipped autoAdvance off as each stop section began never ran, so every stop was played straight past.
- (BOOL)advancesFromIdx:(NSInteger)idx {
    if (![_settings[@"autoAdvance"] boolValue] || idx + 1 >= (NSInteger)_sections.count) return NO;
    NSArray *hold = _settings[@"holdAfter"];
    return !(hold && [hold containsObject:@(idx)]);
}

/// The current section just finished: move to the next one (YES) or pause with step null (NO).
- (BOOL)finishSection {
    if ([self advancesFromIdx:_idx]) {
        [self enterIdx:_idx + 1];
        _stepIdx = 0;
        _repeatDone = 0;
        return YES;
    }
    _stepIdx = 0;
    _repeatDone = 0;
    [self parkAfterRun];
    return NO;
}

/// settings.speakStops entry for the section just finished, or nil.
- (NSDictionary *)speakStopAfterIdx:(NSInteger)idx {
    for (NSDictionary *stop in _settings[@"speakStops"] ?: @[]) {
        if ([stop[@"afterIdx"] integerValue] == idx) return stop;
    }
    return nil;
}

/// The run ended at the current section with nothing to advance to: park with step null (_finished). If the section
/// is a Listen & speak stop and the handler takes it (page cannot show it: screen locked / pocket view up), a native
/// turn starts right here.
/// LOAD-BEARING: the session stays active here (as everywhere, see "Audio session"). iOS only lets a backgrounded app
/// start recording while its audio session is still active; deactivating at the section end would make the turn's
/// AVAudioRecorder fail to start with the screen locked. The turn re-categorizes the live session to playAndRecord.
- (void)parkAfterRun {
    _finished = YES;
    NSDictionary *stop = [self speakStopAfterIdx:_idx];
    if (stop && self.speakStopHandler) self.speakStopHandler(stop);
    [self pausePlayback];
}

/// The turn is over, however it ended. Park paused at the section after the stop: the listener presses play (lock screen or
/// in app) when ready. Never call -play here; a turn that gave up or failed must not quietly carry on either
/// (user report 2026-10-23: "it shouldn't just auto continue").
/// LOAD-BEARING: activateSession puts the live session back on plain playback (the turn left it on playAndRecord) and keeps
/// it active, so the lock-screen card and its play button stay available while paused. _playing is already NO (parkAfterRun
/// paused), so gotoIdx only moves the position.
- (void)parkAfterSpeakTurnFromIdx:(NSInteger)afterIdx {
    NSString *error = [self activateSession];
    if (error) { [self reportError:error]; return; }
    NSInteger next = afterIdx + 1;
    if (next >= (NSInteger)_sections.count) {
        [self publish]; // last section: stay ended
        return;
    }
    error = [self gotoIdx:next];
    if (error) [self reportError:error];
}

/// The gap after a clip elapsed. A loop run whose loop was turned off during the clip or gap ends here.
- (void)gapElapsed {
    if (_loopRun && !_loop) {
        if (_hasContinue) {
            [self startClipKind:@"original"]; // _loopRun stays on, so this clip's end finishes the section
            return;
        }
        _loopRun = NO;
        if (![self finishSection]) return;
        [self startRun];
        return;
    }
    [self startCurrentStep];
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
    if (_loop) {
        *stepIdx = 0;
        *repeat = 0;
        return YES;
    }
    NSString *step = steps[MIN(*stepIdx, (NSInteger)steps.count - 1)];
    NSInteger times = [_settings[@"times"][step] integerValue] ?: 1;
    if (![self playsOriginalOnceIdx:*idx] && *repeat + 1 < times) {
        *repeat += 1;
        return YES;
    }
    *repeat = 0;
    *stepIdx += 1;
    if (*stepIdx < (NSInteger)steps.count) return YES;
    if ([self advancesFromIdx:*idx]) {
        *idx += 1;
        *stepIdx = 0;
        return YES;
    }
    return NO;
}

- (void)clipDidEnd {
    _clipEnded = YES;
    if (_replayKind && _replayQueue.count > 0) {
        _replayKind = _replayQueue[0];
        [_replayQueue removeObjectAtIndex:0];
        [self startClipKind:_replayKind];
        [self publish];
        return;
    }
    if (_replayKind) {
        _replayKind = nil;
        BOOL advance = _replayAdvance;
        _replayAdvance = NO;
        if (_resumeAfterReplay) {
            _resumeAfterReplay = NO;
            _playing = YES;
            _repeatDone = 0;
            _loopRun = _loop;
            if (_loop) _stepIdx = 0;
            // after:"advance": count the section as finished, unless looping (then back to looping it).
            if (advance && !_loop && ![self finishSection]) {
                [self publish];
                return;
            }
            [self scheduleNextStep];
        } else {
            [self pausePlayback];
        }
        [self publish];
        return;
    }
    if (_loopRun) {
        // Loop on: the same original again after the gap. Whether to stop is decided when the gap elapses.
        [self scheduleNextStep];
        [self publish];
        return;
    }
    while (_chainNextIdx >= 0) [self enterChainedSection]; // the run ended: any section not yet entered counts as played
    NSInteger idx = _idx, step = _stepIdx, repeat = _repeatDone;
    if ([self advanceIdx:&idx step:&step repeat:&repeat]) {
        [self enterIdx:idx]; _stepIdx = step; _repeatDone = repeat;
        [self scheduleNextStep];
    } else {
        [self parkAfterRun];
    }
    [self publish];
}

- (void)scheduleNextStep {
    [self cancelGap];
    __weak typeof(self) weakSelf = self;
    _gapTimer = [NSTimer scheduledTimerWithTimeInterval:([self continuous] ? 0 : kListenGapSeconds) repeats:NO block:^(NSTimer *timer) {
        ListenPlayer *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_gapTimer = nil;
        [strongSelf gapElapsed];
        [strongSelf publish];
    }];
    [self prefetch];
}

- (void)cancelGap {
    [_gapTimer invalidate];
    _gapTimer = nil;
}

- (void)pausePlayback {
    [self cancelGap];
    if (_replayKind) {
        // A replay interrupted by pause is discarded; play restarts the step.
        _replayKind = nil;
        _replayQueue = nil;
        _resumeAfterReplay = NO;
        _replayAdvance = NO;
        _clipEnded = YES;
    }
    _playing = NO;
    [_player pause];
    // Speech cannot be resumed mid-word like an AVPlayerItem: pausing drops the vocab clip and play restarts it (the same
    // as a paused replay), which is cheap for a few words.
    if (_speechLast) { [self cancelSpeech]; _clipEnded = YES; _clipReady = NO; }
    [self stopStateTimer];
    [self publish];
}

- (void)stopEverything {
    [self cancelGap];
    _replayKind = nil;
    _replayQueue = nil;
    _resumeAfterReplay = NO;
    _replayAdvance = NO;
    _playing = NO;
    [self discardCurrentItem];
    [self stopStateTimer];
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
    if ([kind isEqual:@"vocab"] && [_sections[_idx][@"audio"][@"vocab"] isKindOfClass:[NSDictionary class]]) { [self startVocabClip]; return; }
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
    // A word-loop range applies to the looping original only, never to a rewind/replay clip (same as the JS engine).
    BOOL ranged = isOriginal && _loop && _hasLoopRange && _replayKind == nil;
    BOOL cont = isOriginal && _hasContinue && _replayKind == nil;
    _hasContinue = NO;
    _clipStart = isOriginal ? (cont ? _continueStart : ranged ? _loopRangeStart : [section[@"start"] doubleValue]) : 0;
    _clipEnd = isOriginal ? (ranged && !cont ? _loopRangeEnd : [section[@"end"] doubleValue]) : 0;
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
    if (isOriginal) [self armChain];
    [self prefetch];
}

/// The vocab step: each term in the target-language voice, a 350 ms pause, its gloss in the native-language voice, a
/// 700 ms pause (the same timings the old Azure ssmlVocab clip had), via postUtteranceDelay on one queued utterance per
/// word. The clip ends when the LAST utterance finishes; that one carries no trailing delay because the 0.4 s step gap
/// already follows every clip. Unverified on device: that the synthesizer keeps speaking with the screen locked under the
/// Playback session category, and that didFinish fires after (not before) postUtteranceDelay on iOS versions in use.
- (void)startVocabClip {
    [self cancelGap];
    [self discardCurrentItem];
    NSDictionary *section = _sections[_idx];
    NSDictionary *locales = section[@"audio"][@"vocab"];
    AVSpeechSynthesisVoice *targetVoice = [AVSpeechSynthesisVoice voiceWithLanguage:locales[@"target"]];
    AVSpeechSynthesisVoice *nativeVoice = [AVSpeechSynthesisVoice voiceWithLanguage:locales[@"native"]];
    if (!targetVoice || !nativeVoice) {
        _playing = NO;
        _replayKind = nil;
        [self reportError:[NSString stringWithFormat:@"section %ld: no voice for %@ / %@", (long)_idx, locales[@"target"], locales[@"native"]]];
        return;
    }
    _clipKind = @"vocab";
    _clipStart = 0;
    _clipEnd = 0;
    _clipRate = 1;
    _clipReady = YES; // nothing to load; the Now Playing "sounding" check wants this
    _clipEnded = NO;
    NSArray<NSDictionary *> *terms = section[@"vocab"];
    NSMutableArray<AVSpeechUtterance *> *queue = [NSMutableArray array];
    for (NSDictionary *t in terms) {
        AVSpeechUtterance *term = [AVSpeechUtterance speechUtteranceWithString:t[@"term"]];
        term.voice = targetVoice;
        term.postUtteranceDelay = 0.35;
        AVSpeechUtterance *gloss = [AVSpeechUtterance speechUtteranceWithString:t[@"gloss"]];
        gloss.voice = nativeVoice;
        gloss.postUtteranceDelay = 0.7;
        [queue addObject:term];
        [queue addObject:gloss];
    }
    queue.lastObject.postUtteranceDelay = 0;
    _speechLast = queue.lastObject;
    // Every caller of startClipKind already wants audio (play set _playing, or a rewind/replay is running), so speak now.
    for (AVSpeechUtterance *u in queue) [_speech speakUtterance:u];
    [self startStateTimer];
    [self prefetch];
}

- (void)cancelSpeech {
    _speechLast = nil; // before stopSpeaking, so the cancel callbacks are not mistaken for the clip finishing
    [_speech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (utterance != self->_speechLast) return; // an earlier word, or a clip that was discarded meanwhile
        self->_speechLast = nil;
        [self clipDidEnd];
    });
}

/// Continuous mode: the original clip of a normal-loop run (autoAdvance on, not loop/range-loop/rewind/replay) is one
/// AVPlayerItem from the current section to the END OF THE SONG: forwardPlaybackEndTime is the last section's end from the
/// start, so there is no item switch at line boundaries. A 20 Hz periodic observer only compares the playhead against the
/// next section's start and enters that section (idx, furthest, stepIdx 0); _clipStart stays the first section's start.
- (void)armChain {
    [self removeChainObserver];
    if (![self continuous] || _loop || _loopRun || _replayKind || ![_clipKind isEqual:@"original"] || !_currentItem) return;
    if (![self advancesFromIdx:_idx]) return;
    // A held section later in the song must end its clip there, so the run is only chained when no hold lies ahead.
    for (NSNumber *h in _settings[@"holdAfter"] ?: @[]) if (h.integerValue > _idx) return;
    _chainNextIdx = _idx + 1;
    _clipEnd = [[_sections lastObject][@"end"] doubleValue];
    _currentItem.forwardPlaybackEndTime = CMTimeMakeWithSeconds(_clipEnd, 1000);
    AVPlayerItem *item = _currentItem;
    __weak typeof(self) weakSelf = self;
    _chainObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 20) queue:dispatch_get_main_queue()
                                                      usingBlock:^(CMTime time) {
        ListenPlayer *strongSelf = weakSelf;
        if (!strongSelf || item != strongSelf->_currentItem) return;
        double now = CMTimeGetSeconds(time);
        BOOL entered = NO;
        while (strongSelf->_chainNextIdx >= 0 &&
               now >= [strongSelf->_sections[strongSelf->_chainNextIdx][@"start"] doubleValue]) {
            [strongSelf enterChainedSection];
            entered = YES;
        }
        if (entered) [strongSelf publish];
    }];
}

- (void)removeChainObserver {
    if (_chainObserver) [_player removeTimeObserver:_chainObserver];
    _chainObserver = nil;
    _chainNextIdx = -1;
}

/// Playback reached the next section's start: that section is now current, at step 0 (original). The item is untouched.
- (void)enterChainedSection {
    NSInteger entered = _chainNextIdx;
    [self enterIdx:entered];
    _stepIdx = 0;
    _repeatDone = 0;
    if (entered + 1 < (NSInteger)_sections.count) _chainNextIdx = entered + 1;
    else [self removeChainObserver];
}

- (void)detachCurrentItem {
    [self removeChainObserver];
    if (!_currentItem) return;
    [_currentItem removeObserver:self forKeyPath:@"status" context:ListenItemStatusContext];
    for (id token in _itemObservers) [[NSNotificationCenter defaultCenter] removeObserver:token];
    _itemObservers = nil;
    _currentItem = nil;
}

- (void)discardCurrentItem {
    [_player pause];
    [self cancelSpeech];
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
    [self pausePlayback];
    [self reportError:message];
}

- (void)beginAudio {
    _player.defaultRate = (float)_clipRate;
    [_player play];
    [self startStateTimer];
}

#pragma mark - Audio session

// The session is activated on play and never deactivated: iOS drops the lock-screen / Control Center Now Playing card
// once the session goes inactive, and only lets a backgrounded app start audio (the next episode, a speak turn's
// recording) on a session that is still active. The cost is that other apps' audio does not auto-resume when Listen
// stops.
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

- (void)audioSessionInterruption:(NSNotification *)note {
    AVAudioSessionInterruptionType type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        GLLog(@"interruption began (playing=%d)", self.playing);
        _resumeAfterInterruption = self.playing;
        if (self.playing) [self pausePlayback];
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
        dispatch_async(dispatch_get_main_queue(), ^{ [self pausePlayback]; });
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
    if (_loopRun && !_loop) return @"original"; // loop turned off mid-run: the original in flight finishes first
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
        @"loop": @(_loop),
        @"loopRange": _hasLoopRange ? @{@"start": @(_loopRangeStart), @"end": @(_loopRangeEnd)} : [NSNull null],
        @"clipStart": _currentItem && [_clipKind isEqual:@"original"] ? @(_clipStart) : [NSNull null],
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

/// Fetches the item's picture for the lock screen. Until it arrives (or when the item has none, or the fetch fails) the
/// card shows the app icon. The response is cacheable (immutable), so URLSession's cache serves it offline after the
/// first fetch.
- (void)fetchArtwork:(NSURL *)url {
    _artworkURL = url;
    _artwork = nil;
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            ListenPlayer *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_artworkURL isEqual:url]) return;
            if (!image) {
                GLLog(@"artwork %@ failed: %@ (HTTP %ld)", url.absoluteString, error.localizedDescription,
                      (long)([response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0));
                return;
            }
            strongSelf->_artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size) { return image; }];
            [strongSelf updateNowPlaying];
        });
    }] resume];
}

static MPMediaItemArtwork *ListenAppIconArtwork(void) {
    static MPMediaItemArtwork *artwork;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *icon = [UIImage imageNamed:@"NowPlayingIcon"];
        NSCAssert(icon, @"NowPlayingIcon missing from Assets.xcassets");
        artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:icon.size requestHandler:^UIImage *(CGSize size) { return icon; }];
    });
    return artwork;
}

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
    NSString *progress = [NSString stringWithFormat:@"%@ · %ld/%lu",
                          step ? ListenStepLabel(step) : @"Done", (long)_idx + 1, (unsigned long)_sections.count];
    BOOL sounding = self.playing && _clipReady && !_clipEnded;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{
        MPMediaItemPropertyTitle: _title,
        MPMediaItemPropertyArtist: progress,
        MPMediaItemPropertyAlbumTitle: @"Listen",
        MPMediaItemPropertyArtwork: _artwork ?: ListenAppIconArtwork(),
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
