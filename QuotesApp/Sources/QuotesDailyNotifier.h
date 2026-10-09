// Once-a-day SILENT local notification carrying a quote. App-only (not
// compiled into the widget): the preference lives in NSUserDefaults, not the
// shared keychain document.
//
// "Silent" = no sound and Passive interruption level (delivered to
// Notification Center without lighting the screen or buzzing).
//
// A repeating calendar trigger would show the same quote forever, so this
// schedules a rolling window of one non-repeating request per upcoming day,
// each with its own quote, and rebuilds the window on every -refresh.

#import <Foundation/Foundation.h>

#import <UserNotifications/UserNotifications.h>

#import "QuotesModels.h"
#import "QuotesStore.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const QuotesDailyNotificationIdentifierPrefix;

extern NSString *const QuotesDailyCategoryIdentifier;
extern NSString *const QuotesDailySaveActionIdentifier;

/// How many upcoming days are scheduled at once.
extern const NSInteger QuotesDailyNotificationDaysAhead;

@interface QuotesDailyEntry : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSDateComponents *dateComponents;
@property(nonatomic, strong, readonly) GLQuote *quote;
@end

@interface QuotesDailyNotifier : NSObject

+ (BOOL)isEnabled;
/// Minutes after local midnight, 0...1439. Default 09:00.
+ (NSInteger)minuteOfDay;

/// Persists the preference, asks for notification permission if it was never
/// asked, and rebuilds the schedule.
+ (void)setEnabled:(BOOL)enabled minuteOfDay:(NSInteger)minuteOfDay;

/// Rebuilds the pending daily requests from current rules/quotes. Cheap;
/// called at launch, whenever the Quotes tab appears, and after any change.
+ (void)refresh;

/// The category carrying the single "Save" action (background, no app
/// foreground). The app registers it with the notification center at launch.
+ (UNNotificationCategory *)notificationCategory;

/// Pure content building for one day's request: title/body, silent + passive,
/// the category above, and userInfo @{@"quoteId": ...} for the Save action.
+ (UNMutableNotificationContent *)contentForEntry:(QuotesDailyEntry *)entry;

/// Handles a tapped notification action. For the Save action, saves the
/// userInfo's quoteId into `store` and returns the save's result; any other
/// action does nothing and returns NO with `error` untouched.
+ (BOOL)handleActionIdentifier:(NSString *)actionIdentifier
                      userInfo:(NSDictionary *)userInfo
                         store:(QuotesStore *)store
                         error:(NSError **)error;

/// Pure scheduling logic: one entry per day in [now's day, +daysAhead) whose
/// fire time (`minuteOfDay` local) is still after `now`. The day's quote comes
/// from the rule matching that weekday + minute (QuotesRuleEngine), indexed by
/// day number so consecutive days differ. Days whose pool is empty (an AI rule
/// not yet resolved, a filter matching nothing) get no entry.
+ (NSArray<QuotesDailyEntry *> *)entriesFromDate:(NSDate *)now
                                        daysAhead:(NSInteger)daysAhead
                                      minuteOfDay:(NSInteger)minuteOfDay
                                            rules:(NSArray<GLQuoteRule *> *)rules
                                           quotes:(NSArray<GLQuote *> *)quotes
                             defaultRotateMinutes:(NSInteger)defaultRotateMinutes
                                         calendar:(NSCalendar *)calendar;

@end

NS_ASSUME_NONNULL_END
