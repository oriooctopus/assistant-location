#import "EsmeViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port. A separate backend
// team owns the server on this port (~/coding/assistant/esme-checkin, not
// this repo) -- this file just needs to point at the right port, not wait on
// or verify that server is live.
static NSInteger const kEsmePort = 8323;

// Posted by EsmeModule's UNUserNotificationCenterDelegate when the user taps
// the daily 21:00 reminder (see EsmeModule.m). Same cross-process-safe
// pattern AutoJournalViewController uses for GLJournalStartCapture/
// GLJournalStartTextEntry: a plain NSNotificationCenter broadcast rather than
// a stored reference, because the thing posting it (a notification-center
// delegate, owned by EsmeModule, not by any view controller) has no
// reference to this instance.
static NSString *const kEsmeStartCheckinNotification = @"GLEsmeStartCheckin";

@implementation EsmeViewController

- (instancetype)init {
    // Trailing slash omitted deliberately -- unlike Finances' lm-review
    // server, the backend team building this on :8323 has given no reason
    // (yet) to expect a Vite dev-server proxy quirk at a nested path; plain
    // http://GL_BAKED_HOST:8323/ is what the brief specifies.
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kEsmePort];
    self = [self initWithURL:[NSURL URLWithString:urlString] displayName:@"esme"];
    if (self) {
        // Registered here, not -viewDidLoad: same reasoning as
        // AutoJournalViewController's -init (see its comment) -- every
        // module's +makeViewController, and therefore this initializer, runs
        // at launch before EsmeModule's notification delegate can possibly
        // receive a tap, whether that tap triggers a cold launch or a
        // foreground handoff.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(handleStartCheckinNotification)
                                                      name:kEsmeStartCheckinNotification
                                                    object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Fired when the user taps the daily check-in notification. Esme is a plain
// web tab, NOT wrapped in its own UINavigationController the way Journal is
// (see AutoJournalModule.m) -- this VC IS its own entry in
// tabs.viewControllers directly, so unlike AutoJournalViewController's
// -selectJournalTab there is no navigation-controller indirection to look
// through here.
- (void)handleStartCheckinNotification {
    UITabBarController *tabs = self.tabBarController;
    if (tabs && [tabs.viewControllers indexOfObject:self] != NSNotFound) {
        tabs.selectedViewController = self;
    }
    // -callWebFunctionIfDefined: (GLWebModuleViewController) evaluates
    // `typeof window.esmeOpenCheckin === 'function' && window.esmeOpenCheckin()`
    // -- guarded so calling this before the frontend team's page defines the
    // hook (or before the page has finished loading at all) is a silent
    // no-op rather than a thrown JS exception. The frontend for :8323 is
    // being built in parallel; this native call is a no-op until that page
    // defines window.esmeOpenCheckin.
    [self callWebFunctionIfDefined:@"esmeOpenCheckin"];
}

@end
