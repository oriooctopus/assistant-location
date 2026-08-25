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
