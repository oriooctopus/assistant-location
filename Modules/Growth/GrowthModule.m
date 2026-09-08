#import "GrowthModule.h"

#import "GrowthViewController.h"
#import "GLModuleRegistry.h"

// Private to this file -- nothing outside GrowthModule needs to know the
// storage key itself, only the +noteReviewCompleted/+isWithinQuietWindow
// class methods (GLWebBridge calls the former from its `growthReviewed`
// bridge handler; see GLWebBridge.m). Stored as an NSTimeInterval
// (-timeIntervalSinceReferenceDate), not an NSDate object, so a plain
// -doubleForKey:/-setDouble:forKey: round-trip is enough -- no archiver,
// no risk of an NSDate subclass mismatch across OS versions.
static NSString *const kGLGrowthLastReviewedAtDefaultsKey = @"GLGrowthLastReviewedAt";

// "if i've completed one within the past 2 hours then it shouldnt default
// open to growth it should open in todos" (Oliver, growth-quiet-window
// brief, verbatim) -- 2 hours is his own stated number, not a measured or
// tuned constant, so there's no calibration story to document here.
static NSTimeInterval const kGLGrowthQuietWindowSeconds = 2 * 60 * 60;

@implementation GrowthModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Growth"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"leaf"]; }

+ (NSInteger)moduleOrder { return 100; }

+ (UIViewController *)makeViewController {
    return [[GrowthViewController alloc] init];
}

// The tab the app opens on, both cold and on a resume after a real absence --
// EXCEPT within 2 hours of a completed Growth review (growth-quiet-window
// brief: "if i've completed one within the past 2 hours then it shouldnt
// default open to growth it should open in todos"). Manually tapping the
// Growth tab bypasses this entirely -- that's UITabBarControllerDelegate's
// ordinary tap handling, a completely different code path from
// GLModuleRegistry's +selectDefaultTabInTabBarController:, which only ever
// runs on cold launch / long-absence resume (see GLModule.h's doc comment on
// this method) -- so this NO can never block a deliberate tap. When this
// returns NO, TodosModule's unconditional YES (see TodosModule.m) is what
// the registry falls through to, since Growth (order 100) sorts before
// Todos (order 150).
+ (BOOL)moduleIsDefaultTab { return ![self isWithinQuietWindow]; }

+ (void)noteReviewCompleted {
    [[NSUserDefaults standardUserDefaults] setDouble:[NSDate timeIntervalSinceReferenceDate]
                                               forKey:kGLGrowthLastReviewedAtDefaultsKey];
}

+ (BOOL)isWithinQuietWindow {
    // Test hook (same spirit as SceneDelegate's UITEST_RESUME_THRESHOLD_SECONDS):
    // lets sim-test.yml seed "a review completed N seconds ago" without
    // driving a real swipe through the growth web app, so the quiet
    // window's OTHER branch (NO -> Todos opens) is provable in CI the same
    // way the resume-threshold branches already are. Read lazily HERE rather
    // than written into NSUserDefaults from a
    // +moduleDidFinishLaunchingWithOptions: hook: that hook would add Growth
    // to the registry's launch-hook fan-out roster (which sim-test.yml pins
    // exactly, deliberately) and would leave real test state behind in the
    // simulator's defaults, for a value only ever read right here.
    NSString *secondsAgoOverride = [[NSProcessInfo processInfo] environment][@"UITEST_GROWTH_REVIEWED_SECONDS_AGO"];
    if (secondsAgoOverride.length > 0) {
        return [secondsAgoOverride doubleValue] < kGLGrowthQuietWindowSeconds;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Checked explicitly rather than trusting -doubleForKey:'s 0 default --
    // 0 (NSDate's reference date, 2001-01-01) would otherwise read as
    // "ages ago" and still correctly return NO below, but relying on that
    // coincidence would silently break if the sentinel or reference date
    // ever changed. A user who has never once completed a Growth review
    // must get NO here, not a false positive that starts them permanently
    // on Todos.
    if (![defaults objectForKey:kGLGrowthLastReviewedAtDefaultsKey]) return NO;
    NSTimeInterval lastReviewedAt = [defaults doubleForKey:kGLGrowthLastReviewedAtDefaultsKey];
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - lastReviewedAt;
    return elapsed < kGLGrowthQuietWindowSeconds;
}

@end
