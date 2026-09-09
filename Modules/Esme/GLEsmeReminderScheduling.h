// Pure, testable time-choosing logic for the Esme daily check-in reminder.
// Deliberately separated from EsmeModule.m's UNUserNotificationCenter calls
// (same split as GLTodoOutboxState / GLTabBarButtonLocator elsewhere in this
// repo) so the randomization and date-math can be unit tested with no
// notification center, no simulator, no UIKit at all.
//
// The daily check-in's whole point is sampling Oliver's mood at an
// unpredictable point in the day rather than the same clock time every day
// (a fixed time biases toward whatever mood he's reliably in at that hour) --
// see EsmeModule.m's scheduling call site for the full rationale.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns a random unsigned integer in [0, upperBound) -- the same contract
/// as arc4random_uniform(), as a block so tests can inject a deterministic
/// (or deliberately-broken) source instead of real randomness.
typedef NSUInteger (^GLEsmeRandomUpperBoundSource)(NSUInteger upperBound);

/// Inclusive lower/upper bound of the random reminder window, in local wall
/// clock hours. A reminder can land at exactly 11:00 or exactly 21:00.
FOUNDATION_EXPORT NSInteger const GLEsmeReminderWindowStartHour;   // 11
FOUNDATION_EXPORT NSInteger const GLEsmeReminderWindowEndHour;     // 21

/// The literal prefix every identifier from +identifierForDate:calendar:
/// starts with, so callers can recognize this module's own pending requests
/// among others without reconstructing the format string.
FOUNDATION_EXPORT NSString *const GLEsmeReminderIdentifierPrefix;

/// One day's worth of a scheduling decision: the deterministic identifier for
/// that calendar day plus the (year/month/day/hour/minute) date components
/// chosen for it.
@interface GLEsmeScheduleEntry : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, strong, readonly) NSDateComponents *dateComponents;
- (instancetype)initWithIdentifier:(NSString *)identifier dateComponents:(NSDateComponents *)dateComponents;
@end

@interface GLEsmeReminderScheduling : NSObject

/// Deterministic per-day identifier of the form "EsmeDailyCheckin-YYYY-MM-DD",
/// computed from `date`'s year/month/day in `calendar`. Re-running scheduling
/// for the same calendar day always produces the same identifier, which is
/// what makes re-adding a request for that day REPLACE the existing one
/// (same mechanism the old single fixed-identifier version used, see
/// EsmeModule.m) instead of stacking a duplicate.
+ (NSString *)identifierForDate:(NSDate *)date calendar:(NSCalendar *)calendar;

/// Date components (year/month/day taken from `date` via `calendar`, plus an
/// hour/minute drawn from `randomSource` uniformly within
/// [GLEsmeReminderWindowStartHour:00, GLEsmeReminderWindowEndHour:00])
/// suitable for a non-repeating UNCalendarNotificationTrigger. `randomSource`
/// is called exactly once.
+ (NSDateComponents *)dateComponentsForDate:(NSDate *)date
                                    calendar:(NSCalendar *)calendar
                                randomSource:(GLEsmeRandomUpperBoundSource)randomSource;

/// One GLEsmeScheduleEntry per day from `fromDate` (inclusive) through
/// `fromDate` + `days` - 1, each day's time drawn independently from
/// `randomSource`.
+ (NSArray<GLEsmeScheduleEntry *> *)upcomingScheduleEntriesFromDate:(NSDate *)fromDate
                                                                 days:(NSUInteger)days
                                                             calendar:(NSCalendar *)calendar
                                                         randomSource:(GLEsmeRandomUpperBoundSource)randomSource;

@end

NS_ASSUME_NONNULL_END
