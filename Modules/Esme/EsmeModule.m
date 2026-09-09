#import "EsmeModule.h"

#import "EsmeViewController.h"
#import "GLModuleRegistry.h"

#import <UserNotifications/UserNotifications.h>

// Fixed identifier for the daily check-in reminder. Passing the SAME
// identifier to -addNotificationRequest:withCompletionHandler: on every
// launch REPLACES any earlier pending request rather than stacking a second
// one, which is what makes +scheduleDailyReminder below idempotent across
// repeated cold launches with no separate "already scheduled" check needed.
static NSString *const kEsmeDailyReminderIdentifier = @"EsmeDailyCheckinReminder";

// Broadcast when the user taps the daily reminder notification. See
// EsmeViewController's -init, which observes this the same way
// AutoJournalViewController observes GLJournalStartCapture/
// GLJournalStartTextEntry (AutoJournalModule.m's +moduleHandleURL: doc
// comment on why a plain NSNotification, not a stored reference, is the
// right handoff: this delegate has no reference to any view controller
// instance, only AutoJournalViewController's own -init registration does).
static NSString *const kEsmeStartCheckinNotification = @"GLEsmeStartCheckin";

// UNUserNotificationCenter has exactly one delegate for the whole process,
// and no other module in this app uses UNUserNotificationCenter yet (grepped
// the whole Modules/ tree) -- so this module owns the slot free and clear.
// Still implemented as its own small object, defensively, rather than the
// module class assigning itself: a future module that also needs
// notifications then has one obvious existing delegate to coordinate with
// instead of a bare block silently owning process-wide delegate state.
@interface EsmeNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation EsmeNotificationDelegate

// Fires when the user TAPS the notification -- foreground, background, or a
// cold launch from a terminated state all route through this one method, so
// "tap to open the check-in" needs no separate cold-launch handling. Posts a
// plain NSNotificationCenter notification rather than reaching into a view
// controller directly, since this delegate (owned by EsmeModule, see
// +moduleDidFinishLaunchingWithOptions: below) has no reference to one.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler {
    [[NSNotificationCenter defaultCenter] postNotificationName:kEsmeStartCheckinNotification object:nil];
    completionHandler();
}

@end

@implementation EsmeModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Esme"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"heart.text.square"]; }

// 50: Esme takes over Finances' old visible-tab slot now that Finances has
// moved into the More grid (FinancesModule.m, order 610 — see MODULES.md's
// order list). Visible tab bar becomes Esme | Growth | Todos | Football.
+ (NSInteger)moduleOrder { return 50; }

+ (UIViewController *)makeViewController {
    return [[EsmeViewController alloc] init];
}

// UNUserNotificationCenter.delegate is a WEAK reference -- without a strong
// reference held somewhere for the life of the process, this object would be
// deallocated the instant +moduleDidFinishLaunchingWithOptions: returns,
// silently breaking notification-tap delivery (the delegate method would
// just never fire, with no error anywhere).
static EsmeNotificationDelegate *sNotificationDelegate;

// See GLModule.h / MODULES.md's "Optional hooks" section -- called once from
// application:didFinishLaunchingWithOptions:, before any tab is installed.
+ (void)moduleDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions {
    sNotificationDelegate = [EsmeNotificationDelegate new];
    [UNUserNotificationCenter currentNotificationCenter].delegate = sNotificationDelegate;

    // Check current authorization before requesting: requestAuthorization
    // itself won't re-show a system prompt once the user has already
    // answered once, but calling it unconditionally would still fire a real
    // request (and run its completion handler) on every cold launch for no
    // reason once the answer is already known. Checking first makes "ask
    // once" an explicit part of this code instead of relying on
    // UNUserNotificationCenter's own internal dedup.
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *_Nonnull settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                   completionHandler:^(BOOL granted, NSError *_Nullable error) {
                // Schedule regardless of THIS request's outcome: if denied,
                // +scheduleDailyReminder's -addNotificationRequest: below is
                // a harmless no-op (the system just never delivers it), and
                // if the user later enables notifications in Settings, the
                // very same call on the next cold launch schedules it for
                // real -- no separate re-check path is needed.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self scheduleDailyReminder];
                });
            }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self scheduleDailyReminder];
            });
        }
    }];
}

// Schedules ONE daily repeating local notification at a fixed 21:00 local
// time. Hardcoded for this first pass -- a later pass can expose this as a
// real preference (a stored hour/minute, e.g. via GLDefaultsKeys.h) instead
// of this constant.
+ (void)scheduleDailyReminder {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"Daily check-in";
    content.body = @"How are you feeling today?";
    content.sound = [UNNotificationSound defaultSound];

    // Hour/minute only (no day/month/year) is what makes a
    // UNCalendarNotificationTrigger with repeats:YES fire every day at this
    // time, rather than once on one specific date.
    NSDateComponents *components = [NSDateComponents new];
    components.hour = 21;
    components.minute = 0;
    UNCalendarNotificationTrigger *trigger =
        [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:components repeats:YES];

    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:kEsmeDailyReminderIdentifier
                                              content:content
                                              trigger:trigger];

    // Adding a request with an identifier that's already pending REPLACES it
    // rather than adding a duplicate -- see kEsmeDailyReminderIdentifier's
    // comment above. Errors are not surfaced anywhere further than this nil
    // handler; a failure here just means tonight's reminder doesn't fire,
    // which the next launch's call self-heals since it re-schedules fresh
    // every time.
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                            withCompletionHandler:nil];
}

// Cheap and static rather than an async pending-request lookup:
// -getPendingNotificationRequestsWithCompletionHandler: is the only way to
// confirm the schedule actually took, but it's async and this method must
// return synchronously -- see TrackerModule.m's moduleDiagnosticSummary for
// the shape a synchronous, state-reading summary takes when the state really
// is available synchronously (CLLocationManager's authorizationStatus).
// Esme's equivalent isn't, so this reports intent rather than confirmed
// state, same as every other nil/no-op module's choice not to implement this
// hook at all.
+ (nullable NSString *)moduleDiagnosticSummary {
    return @"Esme: daily check-in reminder scheduled for 21:00";
}

@end
