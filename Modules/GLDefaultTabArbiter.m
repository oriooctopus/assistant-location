#import "GLDefaultTabArbiter.h"

NSString *GLDefaultTabDecisionName(GLDefaultTabDecision decision) {
    switch (decision) {
        case GLDefaultTabDecisionNone: return @"none";
        case GLDefaultTabDecisionKeepCurrent: return @"kept current tab";
        case GLDefaultTabDecisionExplicitNavigationWins: return @"explicit navigation wins";
        case GLDefaultTabDecisionSelectDefault: return @"select default";
    }
    [NSException raise:NSInternalInconsistencyException format:@"unknown GLDefaultTabDecision %ld", (long)decision];
    return nil;
}

@implementation GLDefaultTabArbiter {
    NSTimeInterval _thresholdSeconds;
    // 0 until the first -didEnterBackgroundAt:, so a cold launch (which
    // also gets -sceneWillEnterForeground:) never reads as a long absence.
    NSTimeInterval _backgroundedAt;
    NSUInteger _explicitNavigationCountAtBackground;
    BOOL _resumePending;
}

- (instancetype)initWithThresholdSeconds:(NSTimeInterval)thresholdSeconds {
    if ((self = [super init])) {
        _thresholdSeconds = thresholdSeconds;
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

- (GLDefaultTabDecision)takeDecisionWithExplicitNavigationCount:(NSUInteger)count {
    if (!_resumePending) return GLDefaultTabDecisionNone;
    _resumePending = NO;
    if (_lastElapsedSeconds < _thresholdSeconds) return GLDefaultTabDecisionKeepCurrent;
    if (count != _explicitNavigationCountAtBackground) return GLDefaultTabDecisionExplicitNavigationWins;
    return GLDefaultTabDecisionSelectDefault;
}

@end
