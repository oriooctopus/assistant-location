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
    BOOL _hasSelectedDefault;
    NSTimeInterval _lastDefaultSelectedAt;
    NSTimeInterval _foregroundedAt;
    // 0 until the first -didEnterBackgroundAt:, so a cold launch (which
    // also gets -sceneWillEnterForeground:) never reads as a long absence.
    NSTimeInterval _backgroundedAt;
    NSUInteger _explicitNavigationCountAtBackground;
    BOOL _resumePending;
}

- (instancetype)initWithThresholdSeconds:(NSTimeInterval)thresholdSeconds
                         cooldownSeconds:(NSTimeInterval)cooldownSeconds {
    if ((self = [super init])) {
        _thresholdSeconds = thresholdSeconds;
        _cooldownSeconds = cooldownSeconds;
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
    _foregroundedAt = now;
    _backgroundedAt = 0;
    _resumePending = YES;
}

- (void)didSelectDefaultAt:(NSTimeInterval)now {
    _hasSelectedDefault = YES;
    _lastDefaultSelectedAt = now;
}

- (GLDefaultTabDecision)takeDecisionWithExplicitNavigationCount:(NSUInteger)count
                                              currentScreenHolds:(BOOL)currentScreenHolds {
    if (!_resumePending) return GLDefaultTabDecisionNone;
    _resumePending = NO;
    if (_lastElapsedSeconds < _thresholdSeconds) return GLDefaultTabDecisionKeepCurrent;
    if (count != _explicitNavigationCountAtBackground) return GLDefaultTabDecisionExplicitNavigationWins;
    if (currentScreenHolds) return GLDefaultTabDecisionCurrentTabHolds;
    if (_hasSelectedDefault && _foregroundedAt - _lastDefaultSelectedAt < _cooldownSeconds) {
        return GLDefaultTabDecisionRecentlyShownDefault;
    }
    return GLDefaultTabDecisionSelectDefault;
}

@end
