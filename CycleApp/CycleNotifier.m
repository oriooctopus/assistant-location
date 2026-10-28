#import "CycleNotifier.h"

NSString *const CycleNotifierErrorDomain = @"CycleNotifier";
NSString *const CycleNotificationRouteKey = @"route";

@implementation UNUserNotificationCenter (CycleNotificationCenter)
- (void)getAuthorizationStatusWithCompletionHandler:(void (^)(UNAuthorizationStatus))completionHandler {
    [self getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) { completionHandler(settings.authorizationStatus); }];
}
@end

@interface CycleNotifier ()
@property (nonatomic, strong) id<CycleNotificationCenter> center;
@end

@implementation CycleNotifier

- (instancetype)initWithCenter:(id<CycleNotificationCenter>)center {
    if ((self = [super init])) _center = center;
    return self;
}

+ (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:CycleNotifierErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (UNNotificationRequest *)requestForArgs:(NSDictionary *)args now:(NSDate *)now error:(NSError **)error {
    NSString *identifier = args[@"id"], *title = args[@"title"], *body = args[@"body"], *route = args[@"route"];
    NSNumber *at = args[@"at"];
    for (NSString *key in @[@"id", @"title", @"body", @"route"]) {
        id v = args[key];
        if (![v isKindOfClass:NSString.class] || ![v length]) {
            if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"notify.schedule: '%@' must be a non-empty string, got %@", key, v]];
            return nil;
        }
    }
    if (![at isKindOfClass:NSNumber.class]) {
        if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"notify.schedule: 'at' must be epoch milliseconds, got %@", at]];
        return nil;
    }
    NSTimeInterval seconds = at.doubleValue / 1000.0 - now.timeIntervalSince1970;
    if (seconds <= 0) {
        if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"notify.schedule: 'at' %@ is not in the future (%.1fs ago)", at, -seconds]];
        return nil;
    }
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = UNNotificationSound.defaultSound;
    content.userInfo = @{CycleNotificationRouteKey: route};
    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:seconds repeats:NO];
    return [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
}

- (void)permissionWithCompletion:(void (^)(BOOL))completion {
    [self.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        UNAuthorizationStatus status = settings.authorizationStatus;
        if (status == UNAuthorizationStatusNotDetermined) {
            [self.center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                       completionHandler:^(BOOL granted, NSError *error) {
                if (error) NSLog(@"[Cycle] notification authorization failed: %@", error);
                completion(granted);
            }];
        } else {
            completion(status != UNAuthorizationStatusDenied); // authorized, provisional, ephemeral
        }
    }];
}

+ (NSString *)statusStringForAuthorization:(UNAuthorizationStatus)status {
    if (status == UNAuthorizationStatusNotDetermined) return @"notDetermined";
    if (status == UNAuthorizationStatusDenied) return @"denied";
    return @"granted"; // authorized, provisional, ephemeral
}

- (void)statusWithCompletion:(void (^)(NSString *))completion {
    [self.center getAuthorizationStatusWithCompletionHandler:^(UNAuthorizationStatus status) {
        completion([CycleNotifier statusStringForAuthorization:status]);
    }];
}

- (void)scheduleArgs:(NSDictionary *)args now:(NSDate *)now completion:(void (^)(NSError *))completion {
    NSError *error = nil;
    UNNotificationRequest *request = [CycleNotifier requestForArgs:args now:now error:&error];
    if (!request) { completion(error); return; }
    // Same identifier replaces a pending request; removing first keeps that true for fakes and
    // makes the replacement explicit.
    [self.center removePendingNotificationRequestsWithIdentifiers:@[request.identifier]];
    [self.center addNotificationRequest:request withCompletionHandler:completion];
}

- (void)cancelID:(NSString *)identifier {
    [self.center removePendingNotificationRequestsWithIdentifiers:@[identifier]];
    [self.center removeDeliveredNotificationsWithIdentifiers:@[identifier]];
}

@end
