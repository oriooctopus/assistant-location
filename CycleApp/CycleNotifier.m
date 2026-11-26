#import "CycleNotifier.h"

NSString *const CycleNotifierErrorDomain = @"CycleNotifier";
NSString *const CycleNotificationRouteKey = @"route";
NSString *const CycleNotificationUpsetIDKey = @"upsetId";
NSString *const CycleNotificationNextKey = @"next";
NSString *const CycleNotificationCategoryUpsetCheck = @"upsetcheck";
NSString *const CycleUpsetActionStill = @"still";
NSString *const CycleUpsetActionPassed = @"passed";
NSString *const CycleUpsetAnswerKeyPrefix = @"upsetAnswers:";

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
    NSMutableDictionary *info = [@{CycleNotificationRouteKey: route} mutableCopy];
    // Optional (older pages never send them): the category shows the action buttons; the upset id and `next` let the shell act on an
    // answer without the page. Wrong types are ignored rather than failing the whole schedule.
    NSString *category = args[@"category"], *upsetId = args[@"upsetId"];
    NSDictionary *next = args[@"next"];
    if ([category isKindOfClass:NSString.class] && category.length) content.categoryIdentifier = category;
    if ([upsetId isKindOfClass:NSString.class] && upsetId.length) info[CycleNotificationUpsetIDKey] = upsetId;
    if ([next isKindOfClass:NSDictionary.class]) info[CycleNotificationNextKey] = next;
    content.userInfo = info;
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

@implementation CycleNotifier (UpsetCheck)

// Options is empty on purpose (no UNNotificationActionOptionForeground): the answer is recorded without opening the app. Precedent:
// QuotesApp/Sources/QuotesDailyNotifier.m.
+ (NSSet<UNNotificationCategory *> *)categories {
    UNNotificationAction *still = [UNNotificationAction actionWithIdentifier:CycleUpsetActionStill title:@"Still feeling it" options:0];
    UNNotificationAction *passed = [UNNotificationAction actionWithIdentifier:CycleUpsetActionPassed title:@"It passed" options:0];
    return [NSSet setWithObject:[UNNotificationCategory categoryWithIdentifier:CycleNotificationCategoryUpsetCheck actions:@[still, passed]
                                                                 intentIdentifiers:@[] options:0]];
}

+ (NSDictionary *)upsetAnswerForAction:(NSString *)action userInfo:(NSDictionary *)userInfo now:(NSDate *)now {
    NSString *upsetId = userInfo[CycleNotificationUpsetIDKey];
    if (![upsetId isKindOfClass:NSString.class] || !upsetId.length) return nil;
    if (![action isEqualToString:CycleUpsetActionStill] && ![action isEqualToString:CycleUpsetActionPassed]) return nil;
    // Fractional seconds so two answers in the same second get different store keys, matching the page's Date#toISOString.
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return @{@"id": upsetId, @"ans": action, @"at": [iso stringFromDate:now]};
}

+ (NSDictionary *)nextCheckArgsForUserInfo:(NSDictionary *)userInfo now:(NSDate *)now calendar:(NSCalendar *)calendar {
    NSDictionary *next = userInfo[CycleNotificationNextKey];
    NSString *upsetId = userInfo[CycleNotificationUpsetIDKey];
    if (![next isKindOfClass:NSDictionary.class] || ![upsetId isKindOfClass:NSString.class]) return nil;
    NSDate *at = nil;
    if ([next[@"delayMs"] isKindOfClass:NSNumber.class]) {
        at = [now dateByAddingTimeInterval:[next[@"delayMs"] doubleValue] / 1000.0];
    } else if ([next[@"morning"] boolValue]) {
        // The next 9:00 local that is at least an hour away (the page applies the same rule with the couple's timezone).
        NSDate *nineToday = [calendar dateBySettingHour:9 minute:0 second:0 ofDate:now options:0];
        at = nineToday;
        if ([at timeIntervalSinceDate:now] < 3600) at = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:nineToday options:0];
    }
    if (!at) return nil;
    NSMutableDictionary *args = [@{@"id": [@"upsetchk-" stringByAppendingString:upsetId], @"at": @((long long)([at timeIntervalSince1970] * 1000.0)),
                                   @"title": next[@"title"] ?: @"Still feeling this?", @"body": next[@"body"] ?: @"",
                                   @"route": [@"upset/" stringByAppendingString:upsetId], @"category": CycleNotificationCategoryUpsetCheck,
                                   @"upsetId": upsetId} mutableCopy];
    // The following asks come from `rest`: each is the next 9:00 after the one before it.
    NSArray *rest = next[@"rest"];
    if ([rest isKindOfClass:NSArray.class] && rest.count) {
        args[@"next"] = @{@"title": next[@"title"] ?: @"Still feeling this?", @"body": rest[0], @"rest": [rest subarrayWithRange:NSMakeRange(1, rest.count - 1)], @"morning": @YES};
    }
    return args;
}

@end
