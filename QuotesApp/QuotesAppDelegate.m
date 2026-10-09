#import "QuotesAppDelegate.h"

#import <UserNotifications/UserNotifications.h>

#import "QuotesDailyNotifier.h"
#import "QuotesStore.h"
#import "QuotesViewController.h"
#import "QuotesTheme.h"
#import "QuotesBrowseViewController.h"
#import "QuotesImportViewController.h"
#import "QuotesScheduleViewController.h"

// Hiding the nav bar also disables the edge-swipe back gesture; this turns it
// back on (the root screen has nothing to pop to, so it stays off there).
@interface QuotesNavigationController : UINavigationController <UIGestureRecognizerDelegate>
@end

@implementation QuotesNavigationController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.interactivePopGestureRecognizer.delegate = self;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return self.viewControllers.count > 1;
}
@end

// No scene manifest: a single-window app, so the app delegate owns the window.
@interface QuotesAppDelegate () <UNUserNotificationCenterDelegate>
@end

@implementation QuotesAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.tintColor = [QuotesTheme ink];
    self.window.backgroundColor = [QuotesTheme paper];
    // The nav bar is hidden: pushed screens carry their own text "Back" link
    // (QuotesTheme installBackLinkInViewController:).
    UINavigationController *nav = [[QuotesNavigationController alloc] initWithRootViewController:[[QuotesViewController alloc] init]];
    nav.navigationBarHidden = YES;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
#if DEBUG
    // Screenshot hook (quotes-shots.yml): open straight on a pushed screen.
    NSString *shotScreen = NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_SCREEN"];
    NSDictionary<NSString *, Class> *shotScreens = @{@"index": QuotesBrowseViewController.class,
                                                     @"add": QuotesImportViewController.class,
                                                     @"rules": QuotesScheduleViewController.class};
    if (shotScreens[shotScreen] != nil) {
        [nav pushViewController:[[shotScreens[shotScreen] alloc] init] animated:NO];
    }
#endif

#if DEBUG
    // Screenshot runs: the system permission alert would cover the screen.
    if (NSProcessInfo.processInfo.environment[@"QUOTES_SHOT"] != nil) return YES;
#endif
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
