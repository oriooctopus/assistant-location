#import "TrackerModule.h"

#import "TrackingViewController.h"
#import "TrackerAppLifecycle.h"

@implementation TrackerModule

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
