// Quotes used to live inside this app and queued its daily notification 14
// days ahead as one-shot "quotes-daily-YYYY-MM-DD" requests. Quotes moved to
// its own app (QuotesApp/), but iOS keeps an app's pending requests after the
// code that scheduled them is gone, so the leftovers kept firing from this
// app. Notification centers are per app, so purging here never touches the
// standalone Quotes app's own schedule.
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLLegacyQuotesPurge : NSObject

/// The subset of `identifiers` left behind by the in-app Quotes notifier.
+ (NSArray<NSString *> *)legacyIdentifiersIn:(NSArray<NSString *> *)identifiers;

/// Removes leftover Quotes requests, pending and delivered, from `center`.
+ (void)purgeFromCenter:(UNUserNotificationCenter *)center;

@end

NS_ASSUME_NONNULL_END
