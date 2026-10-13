#import "GLLegacyQuotesPurge.h"

static NSString *const GLLegacyQuotesIdentifierPrefix = @"quotes-daily-";

@implementation GLLegacyQuotesPurge

+ (NSArray<NSString *> *)legacyIdentifiersIn:(NSArray<NSString *> *)identifiers {
    NSPredicate *legacy = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", GLLegacyQuotesIdentifierPrefix];
    return [identifiers filteredArrayUsingPredicate:legacy];
}

+ (void)purgeFromCenter:(UNUserNotificationCenter *)center {
    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
        NSArray<NSString *> *ids = [self legacyIdentifiersIn:[requests valueForKey:@"identifier"]];
        if (ids.count == 0) return;
        NSLog(@"GLLegacyQuotesPurge: removing %lu pending legacy Quotes notifications", (unsigned long)ids.count);
        [center removePendingNotificationRequestsWithIdentifiers:ids];
    }];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSArray<NSString *> *ids = [self legacyIdentifiersIn:[notifications valueForKeyPath:@"request.identifier"]];
        if (ids.count == 0) return;
        [center removeDeliveredNotificationsWithIdentifiers:ids];
    }];
}

@end
