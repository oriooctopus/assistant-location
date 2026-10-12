#import "MarketplaceAppDelegate.h"

#import <UserNotifications/UserNotifications.h>

#import "BakedConfig.h"
#import "MarketplaceOutbox.h"
#import "MarketplaceViewController.h"

// Same ids the push payload (location-server lib/apns.mjs) and the main app use.
static NSString *const kReplyCategoryId = @"FB_REPLY";
static NSString *const kReplyActionId = @"REPLY";

@interface MarketplaceAppDelegate () <UNUserNotificationCenterDelegate>
@property (nonatomic, strong) MarketplaceViewController *viewController;
@property (nonatomic, strong) MarketplaceOutbox *outbox;
@end

@implementation MarketplaceAppDelegate

- (NSURL *)baseURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:8324", GL_BAKED_HOST]];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                  appropriateForURL:nil create:YES error:NULL];
    self.outbox = [[MarketplaceOutbox alloc] initWithFileURL:[support URLByAppendingPathComponent:@"reply-outbox.json"]];

    self.viewController = [[MarketplaceViewController alloc] init];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];

    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = self; // must be set before launch finishes so a cold-launch tap is delivered
    UNTextInputNotificationAction *reply =
        [UNTextInputNotificationAction actionWithIdentifier:kReplyActionId
                                                       title:@"Reply"
                                                     options:UNNotificationActionOptionNone
                                        textInputButtonTitle:@"Send"
                                        textInputPlaceholder:@""];
    [center setNotificationCategories:[NSSet setWithObject:
        [UNNotificationCategory categoryWithIdentifier:kReplyCategoryId actions:@[reply] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone]]];
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
                          completionHandler:^(BOOL granted, NSError *error) {
        if (error) NSLog(@"[Marketplace] notification authorization failed: %@", error);
        if (!granted) NSLog(@"[Marketplace] notification permission not granted");
    }];
    // Every launch: the token can change, and the server only learns it from /register.
    [application registerForRemoteNotifications];

    [self flushOutbox];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [self flushOutbox];
    [self.viewController refresh];
}

- (void)flushOutbox {
    [self.outbox flushWithBaseURL:self.baseURL
                            token:GL_BAKED_TOKEN
                          session:NSURLSession.sharedSession
                         rejected:^(NSDictionary *item) { [self notifyRejected:item]; }
                       completion:nil];
}

- (void)notifyRejected:(NSDictionary *)item {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"Reply not sent";
    content.body = [NSString stringWithFormat:@"The box refused your reply to %@: %@", item[@"buyer"], item[@"lastError"]];
    content.sound = UNNotificationSound.defaultSound;
    [UNUserNotificationCenter.currentNotificationCenter
        addNotificationRequest:[UNNotificationRequest requestWithIdentifier:[@"MarketplaceReplyRejected-" stringByAppendingString:item[@"id"]]
                                                                    content:content trigger:nil]
         withCompletionHandler:^(NSError *error) {
            if (error) NSLog(@"[Marketplace] reply-rejected notification failed: %@", error);
        }];
}

// ---- APNs ----
- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    NSMutableString *hex = [NSMutableString stringWithCapacity:deviceToken.length * 2];
    const unsigned char *bytes = deviceToken.bytes;
    for (NSUInteger i = 0; i < deviceToken.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    NSURLRequest *req = [MarketplaceOutbox requestWithBaseURL:self.baseURL path:@"/register" token:GL_BAKED_TOKEN body:@{@"token": hex}];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { NSLog(@"[Marketplace] APNs token registration failed: %@", error); return; }
        NSInteger status = ((NSHTTPURLResponse *)resp).statusCode;
        if (status / 100 != 2) {
            NSLog(@"[Marketplace] APNs token registration refused: HTTP %ld %@", (long)status,
                  [[NSString alloc] initWithData:data ?: NSData.data encoding:NSUTF8StringEncoding]);
            return;
        }
        NSLog(@"[Marketplace] APNs device token registered");
    }] resume];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    NSLog(@"[Marketplace] APNs remote-notification registration failed: %@", error);
}

// ---- notifications ----
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
    [self.viewController refresh];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler {
    NSDictionary *info = response.notification.request.content.userInfo;
    if ([response.actionIdentifier isEqualToString:kReplyActionId] &&
        [response isKindOfClass:UNTextInputNotificationResponse.class]) {
        [self handleReply:(UNTextInputNotificationResponse *)response completionHandler:completionHandler];
        return;
    }
    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier] &&
        [response.notification.request.content.categoryIdentifier isEqualToString:kReplyCategoryId]) {
        [self.viewController openQuestionWithListing:info[@"listing"] buyer:info[@"buyer"]];
    }
    completionHandler();
}

- (void)handleReply:(UNTextInputNotificationResponse *)response completionHandler:(void (^)(void))completionHandler {
    NSDictionary *info = response.notification.request.content.userInfo;
    NSString *listing = info[@"listing"], *buyer = info[@"buyer"], *text = response.userText;
    if (listing.length == 0 || buyer.length == 0 || text.length == 0) {
        NSLog(@"[Marketplace] dropping reply -- listing=%@ buyer=%@ textLength=%lu", listing, buyer, (unsigned long)text.length);
        completionHandler();
        return;
    }
    // The process can be suspended right after the action; keep it alive until the POST resolves.
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    void (^finish)(void) = ^{
        if (bgTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
            completionHandler();
        }
    };
    bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"MarketplaceReplySend" expirationHandler:^{
        NSLog(@"[Marketplace] background task expired before POST /reply completed");
        finish();
    }];
    NSError *error = nil;
    if (![self.outbox enqueueReplyForListing:listing buyer:buyer text:text error:&error]) {
        NSLog(@"[Marketplace] reply NOT saved (buyer=%@ listing=%@): %@", buyer, listing, error);
        finish();
        return;
    }
    [self.outbox flushWithBaseURL:self.baseURL token:GL_BAKED_TOKEN session:NSURLSession.sharedSession
                         rejected:^(NSDictionary *item) { [self notifyRejected:item]; }
                       completion:finish];
}

@end
