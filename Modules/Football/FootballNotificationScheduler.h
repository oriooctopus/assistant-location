// Schedules a local notification 10 minutes before kickoff for every
// followed ("fixture_yes") football fixture, and cancels one whose fixture
// is no longer followed or no longer in the feed. This is a LOCAL
// notification, not a server push -- the .p8 key in ~/.config/assistant is
// an App Store Connect key, not APNs, and there is no push sender or device
// token registration anywhere in this app. A local notification also fires
// even when the server box is asleep or off the tailnet, which a push
// design would not.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FootballNotificationScheduler : NSObject

/// Fetches GET /api/fixtures and brings the app's pending fixture-*
/// UNNotificationRequests in line with it:
///   - schedules (or, same identifier, replaces) one request per followed
///     fixture at kickoff minus 10 minutes;
///   - cancels any fixture-* request whose fixture is no longer followed or
///     no longer returned by the server (an untapped/un-swiped match);
///   - skips any fixture whose fire time has already passed;
///   - caps the total to the soonest ~30 kickoffs.
///
/// Call on the MAIN THREAD -- it takes a UIApplication background task, and
/// UIKit is main-thread-only. Every call site below is already main-thread.
/// Safe to call as often as needed: the network fetch and every
/// UNUserNotificationCenter call happen asynchronously off the caller's
/// thread, and rescheduling an existing identifier replaces rather than
/// duplicates. Call sites: FootballViewController's -viewDidAppear:
/// (tab opened), and FootballModule's +moduleWillEnterForeground /
/// +moduleDidEnterBackground (the background call matters most -- the
/// normal flow is tap a match, then leave the app).
+ (void)reconcile;

@end

NS_ASSUME_NONNULL_END
