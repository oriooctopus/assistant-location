#import "GrowthModule.h"

#import "GLGrowthQuietWindow.h"
#import "GrowthViewController.h"
#import "GLModuleRegistry.h"

@implementation GrowthModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Growth"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"leaf"]; }

// 660: Growth lives in the More grid now (New Session took the first tab
// slot at 50) -- see MODULES.md's order list, which this must stay in sync
// with. It is still the default tab outside the quiet window; the registry
// opens a More-bucket default by selecting More and pushing it.
+ (NSInteger)moduleOrder { return 660; }

+ (UIViewController *)makeViewController {
    return [[GrowthViewController alloc] init];
}

// The tab the app opens on, both cold and on a resume after a real absence --
// EXCEPT within the quiet window of a completed Growth review (30 minutes, or 4 hours
// after a tile pick; growth-quiet-window brief, originally 2 hours: "if i've completed one within the past 2 hours then it shouldnt
// default open to growth it should open in todos"). Manually tapping the
// Growth tab bypasses this entirely -- that's UITabBarControllerDelegate's
// ordinary tap handling, a completely different code path from
// GLModuleRegistry's +selectDefaultTabInTabBarController:, which only ever
// runs on cold launch / long-absence resume (see GLModule.h's doc comment on
// this method) -- so this NO can never block a deliberate tap. Todos (order
// 150) is checked before Growth (order 660), so Todos' answer is what makes
// the pair exclusive: inside the window Growth says NO and Todos (the
// complement, see TodosModule.m) wins. Growth is a More-bucket module, so
// the registry opens it by selecting More and pushing it.
+ (BOOL)moduleIsDefaultTab { return ![self isWithinQuietWindow]; }

+ (void)noteReviewCompletedWithQuietSeconds:(NSNumber *)quietSeconds {
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:quietSeconds
                                           defaults:[NSUserDefaults standardUserDefaults]
                                                now:[NSDate timeIntervalSinceReferenceDate]];
}

+ (BOOL)isWithinQuietWindow {
    // Test hook (same spirit as SceneDelegate's UITEST_RESUME_THRESHOLD_SECONDS):
    // lets sim-test.yml seed "a review completed N seconds ago" (against the
    // default 30-minute window) without driving a real swipe through the
    // growth web app, so the quiet window's OTHER branch (NO -> Todos opens)
    // is provable in CI the same way the resume-threshold branches already
    // are. Read lazily HERE rather than written into NSUserDefaults from a
    // +moduleDidFinishLaunchingWithOptions: hook: that hook would add Growth
    // to the registry's launch-hook fan-out roster (which sim-test.yml pins
    // exactly, deliberately) and would leave real test state behind in the
    // simulator's defaults, for a value only ever read right here.
    NSString *secondsAgoOverride = [[NSProcessInfo processInfo] environment][@"UITEST_GROWTH_REVIEWED_SECONDS_AGO"];
    if (secondsAgoOverride.length > 0) {
        return [secondsAgoOverride doubleValue] < GLGrowthDefaultQuietSeconds;
    }
    return [GLGrowthQuietWindow isQuietInDefaults:[NSUserDefaults standardUserDefaults]
                                              now:[NSDate timeIntervalSinceReferenceDate]];
}

@end
