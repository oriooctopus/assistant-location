// Esme micro app. See MODULES.md at the repo root.
//
// A private, daily relationship check-in journal (Oliver's own use, tracking
// how he feels day to day). Thin web wrapper like Finances -- see
// EsmeViewController.m -- plus a native daily local-notification reminder
// (this file) that deep-links back into the web app's check-in flow.

#import <Foundation/Foundation.h>
#import "GLModule.h"

NS_ASSUME_NONNULL_BEGIN

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

/// A tapped feeling follow-up whose id has not yet been delivered to the page.
/// On a cold launch the notification delegate fires before EsmeViewController
/// exists (tab bar not installed yet), so the id waits here; the view
/// controller reads it, delivers it once the page defines esmeOpenFeeling, and
/// clears it. One slot, latest tap wins.
+ (nullable NSString *)pendingFeelingId;
+ (void)clearPendingFeelingId:(NSString *)feelingId;

/// Called by the notification delegate when a feeling follow-up is tapped.
+ (void)noteFeelingTapped:(NSString *)feelingId;
@end

NS_ASSUME_NONNULL_END
