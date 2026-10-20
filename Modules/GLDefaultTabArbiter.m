#import "GLDefaultTabArbiter.h"

NSString *GLDefaultTabDecisionName(GLDefaultTabDecision decision) {
    switch (decision) {
        case GLDefaultTabDecisionNone: return @"none";
        case GLDefaultTabDecisionKeepCurrent: return @"kept current tab";
        case GLDefaultTabDecisionExplicitNavigationWins: return @"explicit navigation wins";
        case GLDefaultTabDecisionSelectDefault: return @"select default";
        case GLDefaultTabDecisionCurrentTabHolds: return @"current screen holds";
        case GLDefaultTabDecisionRecentlyShownDefault: return @"default shown recently";
    }
    [NSException raise:NSInternalInconsistencyException format:@"unknown GLDefaultTabDecision %ld", (long)decision];
    return nil;
}

@implementation GLDefaultTabArbiter {
    NSTimeInterval _thresholdSeconds;
    NSTimeInterval _cooldownSeconds;
    NSUserDefaults *_defaults;
    NSTimeInterval (^_wallClock)(void);
    // 0 until the first -didEnterBackgroundAt:, so a cold launch (which
    // also gets -sceneWillEnterForeground:) never reads as a long absence.
    NSTimeInterval _backgroundedAt;
    NSUInteger _explicitNavigationCountAtBackground;
    BOOL _resumePending;
}

- (instancetype)initWithThresholdSeconds:(NSTimeInterval)thresholdSeconds
                         cooldownSeconds:(NSTimeInterval)cooldownSeconds
                                defaults:(NSUserDefaults *)defaults
                               wallClock:(NSTimeInterval (^)(void))wallClock {
    if ((self = [super init])) {
        _thresholdSeconds = thresholdSeconds;
        _cooldownSeconds = cooldownSeconds;
        _defaults = defaults;
        _wallClock = [wallClock copy];
    }
    return self;
}

- (void)didEnterBackgroundAt:(NSTimeInterval)now explicitNavigationCount:(NSUInteger)count {
    _backgroundedAt = now;
    _explicitNavigationCountAtBackground = count;
    _resumePending = NO;
}

- (void)willEnterForegroundAt:(NSTimeInterval)now {
    if (_backgroundedAt <= 0) return;
    _lastElapsedSeconds = now - _backgroundedAt;
    _backgroundedAt = 0;
    _resumePending = YES;
}

static NSString *const kLastSelectedKey = @"GLDefaultTabLastAutoSelectedAt";

- (void)didSelectDefault {
    [_defaults setDouble:_wallClock() forKey:kLastSelectedKey];
}

- (BOOL)defaultShownRecently {
    NSTimeInterval last = [_defaults doubleForKey:kLastSelectedKey];
    if (last == 0) return NO;
    NSTimeInterval since = _wallClock() - last;
    return since >= 0 && since < _cooldownSeconds;
}

- (void)resetCooldown {
    [_defaults removeObjectForKey:kLastSelectedKey];
}

- (GLDefaultTabDecision)takeDecisionWithExplicitNavigationCount:(NSUInteger)count
                                              currentScreenHolds:(BOOL)currentScreenHolds {
    if (!_resumePending) return GLDefaultTabDecisionNone;
    _resumePending = NO;
    if (_lastElapsedSeconds < _thresholdSeconds) return GLDefaultTabDecisionKeepCurrent;
    if (count != _explicitNavigationCountAtBackground) return GLDefaultTabDecisionExplicitNavigationWins;
    if (currentScreenHolds) return GLDefaultTabDecisionCurrentTabHolds;
    if ([self defaultShownRecently]) {
        return GLDefaultTabDecisionRecentlyShownDefault;
    }
    return GLDefaultTabDecisionSelectDefault;
}

@end
