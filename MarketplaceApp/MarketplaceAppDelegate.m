#import "MarketplaceAppDelegate.h"

#import <BackgroundTasks/BackgroundTasks.h>
#import <UserNotifications/UserNotifications.h>

#import "BakedConfig.h"
#import "MarketplaceOutbox.h"
#import "MarketplaceViewController.h"

// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
static NSString *const kRefreshTaskId = @"com.oliverullman.marketplace.refresh";

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
    [center setNotificationCategories:MarketplaceOutbox.notificationCategories];
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
                          completionHandler:^(BOOL granted, NSError *error) {
        if (error) NSLog(@"[Marketplace] notification authorization failed: %@", error);
        if (!granted) NSLog(@"[Marketplace] notification permission not granted");
    }];
    // Every launch: the token can change, and the server only learns it from /register.
    [application registerForRemoteNotifications];

    // Registration has to finish before didFinishLaunching returns.
    [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:kRefreshTaskId usingQueue:nil launchHandler:^(BGTask *task) {
        [self handleRefreshTask:(BGAppRefreshTask *)task];
    }];

    [self flushOutbox];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self scheduleRefresh];
}

- (void)scheduleRefresh {
    BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kRefreshTaskId];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:15 * 60];
    NSError *error = nil;
    if (![BGTaskScheduler.sharedScheduler submitTaskRequest:request error:&error]) {
        NSLog(@"[Marketplace] scheduling background refresh failed: %@", error);
    }
}

- (void)handleRefreshTask:(BGAppRefreshTask *)task {
    [self scheduleRefresh];
    NSURLSessionDataTask *fetch = [self fetchQuestionsWithCompletion:^(BOOL ok) { [task setTaskCompletedWithSuccess:ok]; }];
    task.expirationHandler = ^{ [fetch cancel]; };
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [self flushOutbox];
    [self.viewController refresh];
    [self fetchQuestionsWithCompletion:^(BOOL ok) {}];
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

// Fetches /questions and hands the payload to the page (and so its saved copy), so the
// thread is there before Oliver opens the app or taps a notification. Used by the
// background push and the periodic background refresh.
- (NSURLSessionDataTask *)fetchQuestionsWithCompletion:(void (^)(BOOL ok))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self.baseURL URLByAppendingPathComponent:@"questions"]];
    [req setValue:[@"Bearer " stringByAppendingString:GL_BAKED_TOKEN] forHTTPHeaderField:@"Authorization"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = ((NSHTTPURLResponse *)resp).statusCode;
        if (error || status / 100 != 2) {
            NSLog(@"[Marketplace] questions prefetch failed: HTTP %ld %@", (long)status, error);
            completion(NO);
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![payload isKindOfClass:NSDictionary.class]) {
            NSLog(@"[Marketplace] questions prefetch: bad payload %@", jsonError);
            completion(NO);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.viewController applyPrefetchedQuestions:payload];
            [self clearResolvedNotifications:payload[@"questions"] completion:^{ completion(YES); }];
        });
    }];
    [task resume];
    return task;
}

// A question answered anywhere (Messenger on the web, this app) leaves the list, so its alert goes too.
- (void)clearResolvedNotifications:(NSArray<NSDictionary *> *)questions completion:(void (^)(void))completion {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSMutableDictionary<NSString *, NSDictionary *> *delivered = [NSMutableDictionary dictionary];
        for (UNNotification *n in notifications) delivered[n.request.identifier] = n.request.content.userInfo;
        NSArray<NSString *> *resolved = [MarketplaceOutbox resolvedIdentifiersInDelivered:delivered questions:questions];
        if (resolved.count) [center removeDeliveredNotificationsWithIdentifiers:resolved];
        dispatch_async(dispatch_get_main_queue(), completion);
    }];
}

// Background push (aps.content-available): the alert push for a new message and the silent
// push the server sends when the data changed.
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    [self fetchQuestionsWithCompletion:^(BOOL ok) {
        completionHandler(ok ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultFailed);
    }];
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
    if ([response.actionIdentifier isEqualToString:MarketplaceActionReply] &&
        [response isKindOfClass:UNTextInputNotificationResponse.class]) {
        [self enqueueAndSendListing:info[@"listing"] buyer:info[@"buyer"] text:((UNTextInputNotificationResponse *)response).userText
                  completionHandler:completionHandler];
        return;
    }
    if ([response.actionIdentifier isEqualToString:MarketplaceActionApprove]) {
        // Tapping Approve is Oliver's approval of the exact text the push displayed ("Suggested: ...").
        [self enqueueAndSendListing:info[@"listing"] buyer:info[@"buyer"] text:info[@"suggested"] completionHandler:completionHandler];
        return;
    }
    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier] &&
        [MarketplaceOutbox categoryOpensThread:response.notification.request.content.categoryIdentifier]) {
        NSLog(@"[Marketplace] notification tap -> open listing=%@ buyer=%@", info[@"listing"], info[@"buyer"]);
        [self.viewController openQuestionWithListing:info[@"listing"] buyer:info[@"buyer"]];
    }
    completionHandler();
}

- (void)enqueueAndSendListing:(NSString *)listing buyer:(NSString *)buyer text:(NSString *)text completionHandler:(void (^)(void))completionHandler {
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
