#import "CycleAppDelegate.h"

#import <UserNotifications/UserNotifications.h>

#import "CycleBridge.h"
#import "CycleNotifier.h"
#import "CycleStore.h"
#import "CycleViewController.h"

@interface CycleAppDelegate () <UNUserNotificationCenterDelegate>
@property (nonatomic, strong) CycleBridge *bridge;
@property (nonatomic, strong) CycleStore *store;
@property (nonatomic, strong) CycleNotifier *notifier;
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
    [center setNotificationCategories:[CycleNotifier categories]];
    self.store = store;
    self.notifier = notifier;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = [[CycleViewController alloc] initWithBridge:self.bridge];
    [self.window makeKeyAndVisible];
    // Every launch: the token can change, and the box only learns it from the page's /push/register.
    [application registerForRemoteNotifications];
    return YES;
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    NSMutableString *hex = [NSMutableString stringWithCapacity:deviceToken.length * 2];
    const unsigned char *bytes = deviceToken.bytes;
    for (NSUInteger i = 0; i < deviceToken.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    [self.bridge deliverPushToken:hex];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    NSLog(@"[Cycle] remote notification registration failed: %@", error);
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
    NSDictionary *info = response.notification.request.content.userInfo;
    NSDictionary *answer = [CycleNotifier upsetAnswerForAction:response.actionIdentifier userInfo:info now:[NSDate date]];
    if (answer) {
        // A check-in button (no foreground option, so the page may not be running). The CycleStore is main-thread only, and this
        // delegate method may arrive elsewhere, so hop to main. Record the answer under its own key for the page to drain, and for
        // "still" schedule the following ask from the payload the page left in userInfo.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *key = [NSString stringWithFormat:@"%@%@:%@", CycleUpsetAnswerKeyPrefix, answer[@"id"], answer[@"at"]];
            NSData *json = [NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL];
            NSError *error = nil;
            if (![self.store setValue:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] forKey:key error:&error]) {
                NSLog(@"[Cycle] could not record the upset answer %@: %@", key, error);
            }
            if ([answer[@"ans"] isEqualToString:CycleUpsetActionStill]) {
                NSDictionary *next = [CycleNotifier nextCheckArgsForUserInfo:info now:[NSDate date] calendar:NSCalendar.currentCalendar];
                if (next) [self.notifier scheduleArgs:next now:[NSDate date] completion:^(NSError *e) { if (e) NSLog(@"[Cycle] next upset check not scheduled: %@", e); }];
            }
            // The page is alive and in front (a banner button while open): let it drain now rather than at the next foreground.
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self.bridge foreground];
            completionHandler();
        });
        return;
    }
    NSString *route = info[CycleNotificationRouteKey];
    if ([route isKindOfClass:NSString.class]) [self.bridge deliverRoute:route];
    else NSLog(@"[Cycle] notification %@ tapped with no route", response.notification.request.identifier);
    completionHandler();
}

@end
