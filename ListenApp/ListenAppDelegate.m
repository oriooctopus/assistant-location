#import "ListenAppDelegate.h"

#import <BackgroundTasks/BackgroundTasks.h>
#import <UserNotifications/UserNotifications.h>

#import "ListenBakedConfig.h"
#import "GLLog.h"
#import "ListenViewController.h"

// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist ($(PRODUCT_BUNDLE_IDENTIFIER).refresh), so the guest copy has its own.
static NSString *RefreshTaskId(void) { return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".refresh"]; }

// No scene manifest: a single-window app, so the app delegate owns the window.
@interface ListenAppDelegate () <UNUserNotificationCenterDelegate>
@end

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
    // "Diário reviewed" pushes come from this app (its own APNs token, topic = this bundle id), not the Superapp. The delegate
    // must be set before didFinishLaunching returns so a tap that cold-launches the app is delivered to it. The guest copy
    // (baked guest cookie) has no Diário, so it never asks for notifications.
    if (![GL_BAKED_GUEST_COOKIE length]) {
        UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
        center.delegate = self;
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *error) {
            if (error) GLLog(@"listen: notification authorization failed: %@", error);
            if (!granted) return;
            // Every launch: the token can change, and the server only learns it from /api/push/register.
            dispatch_async(dispatch_get_main_queue(), ^{ [application registerForRemoteNotifications]; });
        }];
    }
    return YES;
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    NSMutableString *hex = [NSMutableString stringWithCapacity:deviceToken.length * 2];
    const unsigned char *bytes = deviceToken.bytes;
    for (NSUInteger i = 0; i < deviceToken.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"api/push/register" relativeToURL:[ListenViewController serverBaseURL]]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"token": hex} options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (error || status != 200) GLLog(@"listen: push token registration failed: %@ (status %ld)", error, (long)status);
        else GLLog(@"listen: push token registered");
    }] resume];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    GLLog(@"listen: registerForRemoteNotifications failed: %@", error);
}

// Tap on a "Diário reviewed" push: userInfo carries listenDiario:<entry id> (same id check as the diario:// URL).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completionHandler {
    id entryId = response.notification.request.content.userInfo[@"listenDiario"];
    if ([entryId isKindOfClass:[NSString class]] && [entryId rangeOfString:@"^[\\w-]{8,64}$" options:NSRegularExpressionSearch].length) {
        [(ListenViewController *)self.window.rootViewController openDiarioEntry:entryId];
    }
    completionHandler();
}

// The server already skips the push while the page is visible, so a foreground arrival is one that raced the away beacon: show it.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
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
    if ([url.host isEqual:@"diario"]) {
        NSString *entryId = [url.path hasPrefix:@"/"] ? [url.path substringFromIndex:1] : url.path;
        if (![entryId rangeOfString:@"^[\\w-]{8,64}$" options:NSRegularExpressionSearch].length) return NO;
        [(ListenViewController *)self.window.rootViewController openDiarioEntry:entryId];
        return YES;
    }
    if (![url.host isEqual:@"practice"]) return NO;
    [(ListenViewController *)self.window.rootViewController openPracticeFromShortcut];
    return YES;
}

@end
