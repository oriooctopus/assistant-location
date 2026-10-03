#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Decides whether a foreground resume resets the app to its default tab.
//
// Two things race on every resume: the "away long enough, go back to the
// default tab" reset, and an explicit destination (a lock-screen widget or
// Control's deep link, a Home-screen quick action, a notification tap). iOS
// does not promise an order between -sceneWillEnterForeground:,
// -scene:openURLContexts: and -sceneDidBecomeActive:, and module handlers can
// navigate later still (Journal retries until its tab bar controller
// exists). So the rule is order-independent: an explicit navigation anywhere
// between going to the background and the reset decision cancels the reset,
// and one arriving after the decision runs later and wins on its own.
//
// Pure state, no UIKit and no clock of its own: SceneDelegate passes the
// time and GLModuleRegistry's explicit-navigation count in, which is what
// lets SharedTests drive every callback ordering directly.
typedef NS_ENUM(NSInteger, GLDefaultTabDecision) {
    // No resume to judge: a cold launch, or an activation with no
    // background in between (Control Center, an alert, a second call).
    GLDefaultTabDecisionNone,
    // Away less than the threshold: a quick app-switch keeps the tab.
    GLDefaultTabDecisionKeepCurrent,
    // Away long enough, but something navigated explicitly this resume.
    GLDefaultTabDecisionExplicitNavigationWins,
    // Away long enough and nothing else claimed the resume.
    GLDefaultTabDecisionSelectDefault,
};

NSString *GLDefaultTabDecisionName(GLDefaultTabDecision decision);

@interface GLDefaultTabArbiter : NSObject

- (instancetype)initWithThresholdSeconds:(NSTimeInterval)thresholdSeconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// `now` must come from a clock that keeps running while the phone sleeps
// (see SceneDelegate's GLContinuousSeconds) -- a locked phone is asleep for
// most of a 30-minute absence.
- (void)didEnterBackgroundAt:(NSTimeInterval)now explicitNavigationCount:(NSUInteger)count;
- (void)willEnterForegroundAt:(NSTimeInterval)now;

// Called from -sceneDidBecomeActive:. Returns a non-None decision at most
// once per background/foreground cycle.
- (GLDefaultTabDecision)takeDecisionWithExplicitNavigationCount:(NSUInteger)count;

// Seconds away in the cycle most recently judged, for logging.
@property (nonatomic, readonly) NSTimeInterval lastElapsedSeconds;

@end

NS_ASSUME_NONNULL_END
