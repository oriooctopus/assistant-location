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

/// Every diagnostic/test method below reports back through one of these,
/// called on the MAIN THREAD exactly once. `title`/`message` are meant to be
/// shown verbatim in a UIAlertController -- plain, no markup -- so a real
/// failure (an addNotificationRequest error, a denied permission) is always
/// visible rather than silently swallowed, which is the whole point of these
/// tools existing.
typedef void (^FootballNotificationTestReport)(NSString *title, NSString *message);

/// Reports whether the Football tab's "notifications are off" banner should
/// be shown, called on the MAIN THREAD exactly once. See
/// +fetchShouldShowDisabledNoticeWithCompletion: for the exact condition.
typedef void (^FootballNotificationNoticeCompletion)(BOOL shouldShowNotice);

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

/// Requests notification authorization ONLY if the current status is still
/// notDetermined -- iOS never re-prompts once answered, so calling this
/// after a denial is a silent no-op and after a grant is pointless noise.
/// Asynchronous; does not block the caller. Call site: FootballModule's
/// +moduleDidFinishLaunchingWithOptions:, so notifications are asked for at
/// app launch the same way location permission is, rather than only the
/// first time the user happens to background/foreground the app or open the
/// Football tab (reconcile's own request, above).
+ (void)requestPermissionAtLaunchIfNotDetermined;

/// Fetches the current UNNotificationSettings and reports (on the MAIN
/// THREAD) whether the Football tab should show its persistent "notifications
/// are off" banner: true when authorization is explicitly denied, or when
/// authorization was granted but the alert setting itself has since been
/// turned off. notDetermined does NOT trigger the notice -- it's a pending
/// state the launch-time request above resolves almost immediately, not a
/// failure to surface.
+ (void)fetchShouldShowDisabledNoticeWithCompletion:(FootballNotificationNoticeCompletion)completion;

/// Variant 1 -- diagnostic only, schedules nothing. Reports the current
/// UNAuthorizationStatus (notDetermined / denied / authorized / provisional /
/// ephemeral) plus whether alerts/sound are enabled. This is the
/// highest-value tool: every other variant's silence is explained by
/// whatever this one reports. Call on the MAIN THREAD.
+ (void)reportPermissionStatusWithCompletion:(FootballNotificationTestReport)completion;

/// Variant 2 -- explicitly calls +requestAuthorizationWithOptions: (shows
/// the system prompt iff status is still notDetermined) and reports
/// granted/denied. Schedules nothing. Call on the MAIN THREAD.
+ (void)requestPermissionWithCompletion:(FootballNotificationTestReport)completion;

/// Variant 3 -- the suspected fix for "instant test notification never
/// fires": requests authorization, and only INSIDE that completion handler
/// (hopped to the main queue) builds and adds a UNNotificationRequest firing
/// ~1 second out. Reports addNotificationRequest's own error (never
/// swallowed) and the pending-request count after adding. Call on the MAIN
/// THREAD.
+ (void)scheduleTestNotificationAfterAuthorizationWithCompletion:(FootballNotificationTestReport)completion;

/// Variant 4 -- same authorization-gated scheduling as variant 3, but fires
/// 10 seconds out instead of ~1, so pressing this and backgrounding the app
/// distinguishes "never fires" from "fires but is suppressed in the
/// foreground". Call on the MAIN THREAD.
+ (void)scheduleTestNotificationIn10SecondsWithCompletion:(FootballNotificationTestReport)completion;

/// Variant 5 -- same authorization-gated scheduling, but with a
/// UNCalendarNotificationTrigger (date components ~10 seconds out) instead
/// of UNTimeIntervalNotificationTrigger, in case the trigger type itself
/// matters. Call on the MAIN THREAD.
+ (void)scheduleTestNotificationViaCalendarTriggerWithCompletion:(FootballNotificationTestReport)completion;

/// Variant 6 -- same authorization-gated scheduling (~1 second out), but
/// with content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive,
/// which can break through an active Focus mode that would otherwise
/// silence a normal alert. Call on the MAIN THREAD.
+ (void)scheduleTimeSensitiveTestNotificationWithCompletion:(FootballNotificationTestReport)completion;

@end

NS_ASSUME_NONNULL_END
