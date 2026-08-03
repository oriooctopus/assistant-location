#import "TrackerModule.h"

#import "TrackingViewController.h"
#import "TrackerAppLifecycle.h"
#import "GLModuleRegistry.h"

@implementation TrackerModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
// Distinct from TrackerAppLifecycle's own +load, which observes app-lifecycle
// notifications for an unrelated reason (see that file) — this class's +load
// is only about tab registration.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Tracker"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"location.fill"]; }

+ (NSInteger)moduleOrder { return 400; }

// TrackingViewController is laid out in Main.storyboard and wired to ~20
// IBOutlets, so it is instantiated from the storyboard rather than built in
// code. The storyboard no longer decides where the tab goes — this does.
+ (UIViewController *)makeViewController {
    UIStoryboard *main = [UIStoryboard storyboardWithName:@"Location" bundle:nil];
    return [main instantiateViewControllerWithIdentifier:@"TrackingViewController"];
}

#pragma mark - GLModule optional hooks
//
// This is the location feature's app-shell integration point (see
// MODULES.md). All the actual logic lives in TrackerAppLifecycle so this
// class stays a thin protocol-conformance shim.

+ (void)moduleDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [TrackerAppLifecycle didFinishLaunchingWithOptions:launchOptions];
}

+ (BOOL)moduleHandleURL:(NSURL *)url {
    return [TrackerAppLifecycle handleURL:url];
}

+ (BOOL)moduleHandleUserActivity:(NSUserActivity *)activity {
    return [TrackerAppLifecycle handleUserActivity:activity];
}

+ (BOOL)moduleHandleShortcutItem:(UIApplicationShortcutItem *)item {
    return [TrackerAppLifecycle handleShortcutItem:item];
}

+ (NSString *)moduleDiagnosticSummary {
    return [TrackerAppLifecycle diagnosticSummary];
}

@end
