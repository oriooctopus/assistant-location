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
// No UIKit and no clock of its own: SceneDelegate passes the absence clock
// and GLModuleRegistry's explicit-navigation count in, and the cooldown's
// wall clock is injected, which is what lets SharedTests drive every callback
// ordering directly. The cooldown start is persisted in NSUserDefaults, so it
// outlives a relaunch (iOS kills a backgrounded app often).
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
    // Away long enough, no explicit navigation, but the screen on display
    // asked to stay (e.g. Journal, which records while the phone is locked).
    GLDefaultTabDecisionCurrentTabHolds,
    // Away long enough and nothing else claimed it, but the default tab was
    // auto-selected less than the cooldown ago, so the user is not yanked
    // there a second time (lock for a few minutes, unlock, navigated again).
    GLDefaultTabDecisionRecentlyShownDefault,
};

NSString *GLDefaultTabDecisionName(GLDefaultTabDecision decision);

@interface GLDefaultTabArbiter : NSObject

// `cooldownSeconds`: after the default tab was auto-selected (see
// -didSelectDefault), neither a resume nor a cold launch selects it again
// within this long. The selection time is stored in `defaults` as wall-clock
// time (the monotonic clock used for absences resets on reboot), so it
// survives a relaunch. `wallClock` returns seconds since the reference date.
- (instancetype)initWithThresholdSeconds:(NSTimeInterval)thresholdSeconds
                         cooldownSeconds:(NSTimeInterval)cooldownSeconds
                                defaults:(NSUserDefaults *)defaults
                               wallClock:(NSTimeInterval (^)(void))wallClock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// `now` (absence clock, not the cooldown's wall clock) must come from a clock that keeps running while the phone sleeps
// (see SceneDelegate's GLContinuousSeconds) -- a locked phone is asleep for
// most of a 30-minute absence.
- (void)didEnterBackgroundAt:(NSTimeInterval)now explicitNavigationCount:(NSUInteger)count;
- (void)willEnterForegroundAt:(NSTimeInterval)now;

// Call after every ACTUAL auto-selection of the default tab (cold launch, or a
// resume where the registry selected it). Starts the cooldown; nothing else does.
- (void)didSelectDefault;

// Whether the default tab was auto-selected less than the cooldown ago. The
// cold-launch path asks this before selecting; resume asks it via
// -takeDecision.... A stored time in the future (clock moved back) counts as
// not recent.
- (BOOL)defaultShownRecently;

// Forget the persisted cooldown start (sim-test hook, UITEST_RESET_DEFAULT_TAB_COOLDOWN).
- (void)resetCooldown;

// Called from -sceneDidBecomeActive:. Returns a non-None decision at most
// once per background/foreground cycle.
// `currentScreenHolds` is whether the module on screen right now opted out of
// the reset (+moduleHoldsTabOnResume). It only matters for a long absence with
// no explicit navigation.
- (GLDefaultTabDecision)takeDecisionWithExplicitNavigationCount:(NSUInteger)count
                                              currentScreenHolds:(BOOL)currentScreenHolds;

// Seconds away in the cycle most recently judged, for logging.
@property (nonatomic, readonly) NSTimeInterval lastElapsedSeconds;

@end

NS_ASSUME_NONNULL_END
