#import "FootballViewController.h"

#import <WebKit/WebKit.h>

#import "BakedConfig.h"
#import "FootballNotificationScheduler.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port. Same port as Events —
// it's the same server, just pinned to the football view via ?tab=football.
static NSInteger const kFootballPort = 8304;

// Message names the Football settings menu (events/web/index.html's
// #football-menu-popup) posts via
// window.webkit.messageHandlers.<name>.postMessage({}) -- the web page has
// no way to fire a native local notification, request permission, or run
// the kickoff scheduler on its own, so it calls back into this bridge
// instead. Registered only on THIS tab's WKUserContentController (see
// -configureUserContentController: below and GLWebModuleViewController's
// matching extension point) -- Events and Todos, the other
// GLWebModuleViewController tabs, never see these handlers.
//
// The six notify* names are the numbered test-notification variants (see
// FootballNotificationScheduler.h for what each one actually does) -- the
// single "Send test notification" tool they replaced silently dropped its
// notification when permission was still notDetermined (scheduled outside
// the authorization completion handler), and there was no way to see that
// failure from the web page. Each variant below reports back through a
// native UIAlertController instead of a toast, specifically so a real
// failure (a denied permission, an addNotificationRequest error) is always
// visible rather than silently swallowed.
static NSString *const kFootballReconcileMessage = @"reconcile";
static NSString *const kFootballPermissionStatusMessage = @"notifyPermissionStatus";
static NSString *const kFootballRequestPermissionMessage = @"notifyRequestPermission";
static NSString *const kFootballNotifyAfterAuthMessage = @"notifyAfterAuth";
static NSString *const kFootballNotifyIn10SecondsMessage = @"notifyIn10Seconds";
static NSString *const kFootballNotifyViaCalendarTriggerMessage = @"notifyViaCalendarTrigger";
static NSString *const kFootballNotifyTimeSensitiveMessage = @"notifyTimeSensitive";

// Pushes the current notification-authorization state into the page (native
// -> page, unlike every message above which is page -> native) so the page
// can show/hide its persistent "notifications are off" banner. The page
// posts this with an empty payload whenever the Football tab is shown; the
// reply comes back via -evaluateJavaScript: on message.webView rather than a
// round trip through gl_presentTestReportWithTitle:message: (that's a modal
// alert, wrong for a state the page needs to render silently).
static NSString *const kFootballPermissionNoticeStatusMessage = @"requestPermissionNoticeStatus";

// Deep-links to this app's own Settings page (Settings can't be opened
// straight to the notification-permission prompt -- iOS has no API for
// that) so a denied user can actually act on the banner above instead of
// hunting for the app in Settings themselves.
static NSString *const kFootballOpenAppSettingsMessage = @"openAppSettings";

@interface FootballViewController () <WKScriptMessageHandler>
@end

@implementation FootballViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/?tab=football", GL_BAKED_HOST, (long)kFootballPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"football"];
}

// WKUserContentController strongly retains its message handlers, and using
// `self` directly here would make the controller (owned by this VC's own
// webView.configuration) hold a strong reference back to this VC -- a
// retain cycle. Left as `self` anyway rather than a weak-proxy indirection:
// every GLModule's view controller is a tab-bar singleton for the process's
// entire lifetime (GLModuleRegistry builds each tab's VC exactly once at
// launch), so there is no dealloc this cycle could ever block.
- (void)configureUserContentController:(WKUserContentController *)controller {
    [super configureUserContentController:controller];
    [controller addScriptMessageHandler:self name:kFootballReconcileMessage];
    [controller addScriptMessageHandler:self name:kFootballPermissionStatusMessage];
    [controller addScriptMessageHandler:self name:kFootballRequestPermissionMessage];
    [controller addScriptMessageHandler:self name:kFootballNotifyAfterAuthMessage];
    [controller addScriptMessageHandler:self name:kFootballNotifyIn10SecondsMessage];
    [controller addScriptMessageHandler:self name:kFootballNotifyViaCalendarTriggerMessage];
    [controller addScriptMessageHandler:self name:kFootballNotifyTimeSensitiveMessage];
    [controller addScriptMessageHandler:self name:kFootballPermissionNoticeStatusMessage];
    [controller addScriptMessageHandler:self name:kFootballOpenAppSettingsMessage];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
       didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:kFootballReconcileMessage]) {
        [FootballNotificationScheduler reconcile];
        return;
    }

    if ([message.name isEqualToString:kFootballPermissionNoticeStatusMessage]) {
        WKWebView *webView = message.webView;
        [FootballNotificationScheduler fetchShouldShowDisabledNoticeWithCompletion:^(BOOL shouldShowNotice) {
            NSString *js = [NSString stringWithFormat:@"window.footballHandlePermissionNoticeStatus(%@);",
                             shouldShowNotice ? @"true" : @"false"];
            [webView evaluateJavaScript:js completionHandler:nil];
        }];
        return;
    }

    if ([message.name isEqualToString:kFootballOpenAppSettingsMessage]) {
        NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if ([[UIApplication sharedApplication] canOpenURL:settingsURL]) {
            [[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
        }
        return;
    }

    FootballNotificationTestReport report = ^(NSString *title, NSString *reportMessage) {
        [self gl_presentTestReportWithTitle:title message:reportMessage];
    };

    if ([message.name isEqualToString:kFootballPermissionStatusMessage]) {
        [FootballNotificationScheduler reportPermissionStatusWithCompletion:report];
    } else if ([message.name isEqualToString:kFootballRequestPermissionMessage]) {
        [FootballNotificationScheduler requestPermissionWithCompletion:report];
    } else if ([message.name isEqualToString:kFootballNotifyAfterAuthMessage]) {
        [FootballNotificationScheduler scheduleTestNotificationAfterAuthorizationWithCompletion:report];
    } else if ([message.name isEqualToString:kFootballNotifyIn10SecondsMessage]) {
        [FootballNotificationScheduler scheduleTestNotificationIn10SecondsWithCompletion:report];
    } else if ([message.name isEqualToString:kFootballNotifyViaCalendarTriggerMessage]) {
        [FootballNotificationScheduler scheduleTestNotificationViaCalendarTriggerWithCompletion:report];
    } else if ([message.name isEqualToString:kFootballNotifyTimeSensitiveMessage]) {
        [FootballNotificationScheduler scheduleTimeSensitiveTestNotificationWithCompletion:report];
    }
}

// Every notify* variant reports back through this rather than a web-page
// toast -- a native alert is readable regardless of whether the app is about
// to be backgrounded (variant 4's whole point) and can't be missed the way a
// toast fading out under a system permission sheet could be.
- (void)gl_presentTestReportWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// One of the three kickoff-reminder reconcile call sites (see
// FootballNotificationScheduler.h) -- fires every time this tab is shown,
// which is also the point a fresh swipe (mark_fixture) is most likely to
// have just happened.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [FootballNotificationScheduler reconcile];
}

@end
