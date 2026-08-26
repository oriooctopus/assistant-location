#import "FootballModule.h"

#import "FootballNotificationScheduler.h"
#import "FootballViewController.h"
#import "GLModuleRegistry.h"

@implementation FootballModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Football"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"soccerball"]; }

+ (NSInteger)moduleOrder { return 350; }

+ (UIViewController *)makeViewController {
    return [[FootballViewController alloc] init];
}

#pragma mark - Launch-time notification permission (GLModule optional hook)

// Requests notification permission at app launch the same way GLManager
// requests location permission -- as part of app start, not gated behind the
// Tracker module's own GLNotificationPermissionRequestedDefaultsName default
// (which drives Tracker's location-notification behaviour and is not ours to
// repurpose). Asynchronous and a no-op once the user has already answered
// (see +requestPermissionAtLaunchIfNotDetermined), so this never blocks
// launch and never re-prompts.
+ (void)moduleDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [FootballNotificationScheduler requestPermissionAtLaunchIfNotDetermined];
}

#pragma mark - Kickoff-reminder reconcile (GLModule optional lifecycle hooks)

// The background call matters most -- the normal flow is tap a match in
// the Football tab, then leave the app, and without this hook that tap
// would not schedule a notification until the next cold launch. See
// FootballNotificationScheduler.h for the full reconcile contract; the
// third call site (the Football tab itself appearing) lives in
// FootballViewController's -viewDidAppear:.
+ (void)moduleWillEnterForeground {
    [FootballNotificationScheduler reconcile];
}

+ (void)moduleDidEnterBackground {
    [FootballNotificationScheduler reconcile];
}

@end
