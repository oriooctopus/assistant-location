#import "ListenAppDelegate.h"

#import <BackgroundTasks/BackgroundTasks.h>

#import "GLLog.h"
#import "ListenViewController.h"

// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist ($(PRODUCT_BUNDLE_IDENTIFIER).refresh), so the guest copy has its own.
static NSString *RefreshTaskId(void) { return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".refresh"]; }

// No scene manifest: a single-window app, so the app delegate owns the window.
@implementation ListenAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ListenViewController alloc] init];
    [self.window makeKeyAndVisible];
    // Background app refresh: iOS wakes the app every so often (its own schedule, from how often the app is used) and the
    // page re-reads its data, so opening it after hours away shows recent data, not the copy from the last use.
    // Registration has to finish before didFinishLaunching returns.
    [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:RefreshTaskId() usingQueue:nil launchHandler:^(BGTask *task) {
        [self handleRefreshTask:(BGAppRefreshTask *)task];
    }];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self scheduleRefresh];
}

- (void)scheduleRefresh {
    BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:RefreshTaskId()];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:30 * 60];
    NSError *error = nil;
    if (![BGTaskScheduler.sharedScheduler submitTaskRequest:request error:&error]) GLLog(@"listen: scheduling background refresh failed: %@", error);
}

- (void)handleRefreshTask:(BGAppRefreshTask *)task {
    [self scheduleRefresh];
    // Once only: the page's answer and the expiration can both arrive.
    __block BOOL finished = NO;
    void (^finish)(BOOL) = ^(BOOL ok) {
        if (finished) return;
        finished = YES;
        [task setTaskCompletedWithSuccess:ok];
    };
    task.expirationHandler = ^{ dispatch_async(dispatch_get_main_queue(), ^{ finish(NO); }); };
    dispatch_async(dispatch_get_main_queue(), ^{
        [(ListenViewController *)self.window.rootViewController backgroundRefreshWithCompletion:finish];
    });
}

// <bundle id>://practice, opened by the lock-screen Practice Control (ListenControl/PracticeIntent.swift). The scheme is
// the bundle id (Info.plist CFBundleURLSchemes) so the guest copy, a second app on the same phone, never answers the
// personal app's shortcut. With no scene manifest, a cold launch from the URL also arrives here after
// didFinishLaunching (which returned YES), so this is the one entry point.
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    if (![url.host isEqual:@"practice"]) return NO;
    [(ListenViewController *)self.window.rootViewController openPracticeFromShortcut];
    return YES;
}

@end
