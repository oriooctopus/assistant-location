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
// no way to fire a native local notification or run the kickoff scheduler
// on its own, so it calls back into this bridge instead. Registered only on
// THIS tab's WKUserContentController (see -configureUserContentController:
// below and GLWebModuleViewController's matching extension point) -- Events
// and Todos, the other GLWebModuleViewController tabs, never see these
// handlers.
static NSString *const kFootballTestNotificationMessage = @"testNotification";
static NSString *const kFootballReconcileMessage = @"reconcile";

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
    [controller addScriptMessageHandler:self name:kFootballTestNotificationMessage];
    [controller addScriptMessageHandler:self name:kFootballReconcileMessage];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
       didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:kFootballTestNotificationMessage]) {
        [FootballNotificationScheduler sendImmediateTestNotification];
    } else if ([message.name isEqualToString:kFootballReconcileMessage]) {
        [FootballNotificationScheduler reconcile];
    }
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
