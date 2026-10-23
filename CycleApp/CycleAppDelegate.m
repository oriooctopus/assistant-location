#import "CycleAppDelegate.h"

#import <UserNotifications/UserNotifications.h>

#import "CycleBridge.h"
#import "CycleNotifier.h"
#import "CycleStore.h"
#import "CycleViewController.h"

@interface CycleAppDelegate () <UNUserNotificationCenterDelegate>
@property (nonatomic, strong) CycleBridge *bridge;
@end

@implementation CycleAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                  appropriateForURL:nil create:YES error:NULL];
    NSAssert(support, @"Application Support directory unavailable");
    NSError *error = nil;
    CycleStore *store = [[CycleStore alloc] initWithDirectory:support error:&error];
    NSAssert(store, @"cycle store failed to load: %@", error);
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    CycleNotifier *notifier = [[CycleNotifier alloc] initWithCenter:center];
    self.bridge = [[CycleBridge alloc] initWithStore:store notifier:notifier];
    // Must be set before launch finishes so a tap that cold-launched the app is delivered.
    center.delegate = self;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = [[CycleViewController alloc] initWithBridge:self.bridge];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self.bridge foreground];
}

// Banner + sound while the app is open too.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSString *route = response.notification.request.content.userInfo[CycleNotificationRouteKey];
    if ([route isKindOfClass:NSString.class]) [self.bridge deliverRoute:route];
    else NSLog(@"[Cycle] notification %@ tapped with no route", response.notification.request.identifier);
    completionHandler();
}

@end
