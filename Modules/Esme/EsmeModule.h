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
/// `dayKey` ("YYYY-MM-DD", already validated) is completed: persists it so
/// +scheduleDailyReminder never re-adds that day, and removes that day's
/// pending and delivered reminder.
+ (void)noteCheckinCompletedForDay:(NSString *)dayKey;
@end
