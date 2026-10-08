#import "QuotesAppDelegate.h"

#import <UserNotifications/UserNotifications.h>

#import "QuotesDailyNotifier.h"
#import "QuotesStore.h"
#import "QuotesViewController.h"

// No scene manifest: a single-window app, so the app delegate owns the window.
@interface QuotesAppDelegate () <UNUserNotificationCenterDelegate>
@end

@implementation QuotesAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    // Nav controller for the same reason the old tab had one: the Schedule
    // segment pushes a rule-edit screen.
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[QuotesViewController alloc] init]];
    [self.window makeKeyAndVisible];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center setNotificationCategories:[NSSet setWithObject:[QuotesDailyNotifier notificationCategory]]];

    // First launch: ask once (the notifier's default is on), then schedule.
    // Every later launch just tops the window up.
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if ([QuotesDailyNotifier isEnabled] && settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                                   completionHandler:^(BOOL granted, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{ [QuotesDailyNotifier refresh]; });
            }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ [QuotesDailyNotifier refresh]; });
        }
    }];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [QuotesDailyNotifier refresh];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSError *error = nil;
    [QuotesDailyNotifier handleActionIdentifier:response.actionIdentifier
                                       userInfo:response.notification.request.content.userInfo
                                          store:[QuotesStore sharedStore]
                                          error:&error];
    if (error) NSLog(@"[Quotes] Save action failed: %@", error);
    completionHandler();
}

@end
