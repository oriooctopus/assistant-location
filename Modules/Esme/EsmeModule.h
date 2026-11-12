// Esme micro app. See MODULES.md at the repo root.
//
// A private, daily relationship check-in journal (Oliver's own use, tracking
// how he feels day to day). Thin web wrapper like Finances -- see
// EsmeViewController.m -- plus a native daily local-notification reminder
// (this file) that deep-links back into the web app's check-in flow.

#import <Foundation/Foundation.h>
#import "GLModule.h"

@interface EsmeModule : NSObject <GLModule>

/// Called (via GLWebBridge `esmeCheckinDone`) when the daily check-in for
/// `dayKey` ("YYYY-MM-DD", already validated) is completed: removes that
/// day's delivered reminder, leaving a still-pending one scheduled.
+ (void)noteCheckinCompletedForDay:(NSString *)dayKey;

/// Called (via GLWebBridge `esmeFeelingSchedule`, params already validated)
/// to schedule the discreet follow-up for `feelingId` at `fireAt`. Replaces an
/// earlier one for the same id; schedules nothing when `fireAt` is past.
+ (void)scheduleFeelingFollowUp:(NSString *)feelingId fireAt:(NSDate *)fireAt;

/// Called (via GLWebBridge `esmeFeelingCancel`) to drop the pending and
/// delivered follow-up for `feelingId`.
+ (void)cancelFeelingFollowUp:(NSString *)feelingId;
@end
