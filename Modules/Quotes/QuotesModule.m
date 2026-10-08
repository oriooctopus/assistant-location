// Overland-only retirement shim. Quotes is a standalone app now (QuotesApp/,
// see MODULES.md), so this is no longer a GLModule and registers no tab. It
// is NOT compiled into the Quotes target.
//
// Overland scheduled up to 14 daily-quote notifications before the split. The
// new app schedules its own, so once per launch Overland clears the leftovers
// (pending and already delivered) to keep the two from doubling up.

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#import "QuotesDailyNotifier.h"

@interface QuotesModule : NSObject
@end

@implementation QuotesModule

+ (void)load {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clearLegacyDailyNotifications)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
}

+ (void)clearLegacyDailyNotifications {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
        [center removePendingNotificationRequestsWithIdentifiers:[self legacyIdentifiersIn:requests]];
    }];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSMutableArray<UNNotificationRequest *> *requests = [NSMutableArray array];
        for (UNNotification *notification in notifications) [requests addObject:notification.request];
        [center removeDeliveredNotificationsWithIdentifiers:[self legacyIdentifiersIn:requests]];
    }];
}

+ (NSArray<NSString *> *)legacyIdentifiersIn:(NSArray<UNNotificationRequest *> *)requests {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (UNNotificationRequest *request in requests) {
        if ([request.identifier hasPrefix:QuotesDailyNotificationIdentifierPrefix]) [ids addObject:request.identifier];
    }
    return ids;
}

@end
