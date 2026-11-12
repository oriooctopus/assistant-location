#import "EsmeViewController.h"

#import "BakedConfig.h"
#import "EsmeModule.h"
#import "GLModuleRegistry.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port. A separate backend
// team owns the server on this port (~/coding/assistant/esme-checkin, not
// this repo) -- this file just needs to point at the right port, not wait on
// or verify that server is live.
static NSInteger const kEsmePort = 8323;

// Same retry budget as TodosModule's openPractice: 40 x 0.2s, ~8s for a cold
// WKWebView load.
static NSInteger const kEsmeFeelingMaxAttempts = 40;
static NSTimeInterval const kEsmeFeelingRetryInterval = 0.2;

// Posted by EsmeModule's UNUserNotificationCenterDelegate when the user taps
// the daily 21:00 reminder (see EsmeModule.m). Same cross-process-safe
// pattern AutoJournalViewController uses for GLJournalStartCapture/
// GLJournalStartTextEntry: a plain NSNotificationCenter broadcast rather than
// a stored reference, because the thing posting it (a notification-center
// delegate, owned by EsmeModule, not by any view controller) has no
// reference to this instance.
static NSString *const kEsmeStartCheckinNotification = @"GLEsmeStartCheckin";

// Posted when a per-feeling follow-up is tapped; the id is
// +[EsmeModule pendingFeelingId].
static NSString *const kEsmeOpenFeelingNotification = @"GLEsmeOpenFeeling";

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
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(handleOpenFeelingNotification:)
                                                      name:kEsmeOpenFeelingNotification
                                                    object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Fired when the user taps the daily check-in notification.
- (void)handleStartCheckinNotification {
    [GLModuleRegistry showModuleWithIdentifier:@"GLModule.EsmeModule"];
    // -callWebFunctionIfDefined: (GLWebModuleViewController) evaluates
    // `typeof window.esmeOpenCheckin === 'function' && window.esmeOpenCheckin()`
    // -- guarded so calling this before the frontend team's page defines the
    // hook (or before the page has finished loading at all) is a silent
    // no-op rather than a thrown JS exception. The frontend for :8323 is
    // being built in parallel; this native call is a no-op until that page
    // defines window.esmeOpenCheckin.
    [self callWebFunctionIfDefined:@"esmeOpenCheckin"];
}

// Fired when the user taps a per-feeling follow-up notification.
- (void)handleOpenFeelingNotification:(NSNotification *)note {
    [GLModuleRegistry showModuleWithIdentifier:@"GLModule.EsmeModule"];
    [self deliverPendingFeelingAttemptsLeft:kEsmeFeelingMaxAttempts];
}

// Delivers +[EsmeModule pendingFeelingId] (JSON-encoded) to window.esmeOpenFeeling,
// retrying until the page has loaded and defines it (a tap from a killed app
// reaches a page that is still booting), then clears it. Reads the pending id
// afresh on each attempt, so a later tap wins; a second chain started by that
// tap finds nothing pending once the first delivers and stops.
- (void)deliverPendingFeelingAttemptsLeft:(NSInteger)attemptsLeft {
    NSString *feelingId = [EsmeModule pendingFeelingId];
    if (!feelingId) return;
    __weak typeof(self) weakSelf = self;
    void (^retry)(void) = ^{
        if (attemptsLeft <= 1) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEsmeFeelingRetryInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf deliverPendingFeelingAttemptsLeft:attemptsLeft - 1];
        });
    };
    // The web view only exists once the view has loaded; the completion below
    // is never called without one.
    if (!self.isViewLoaded) {
        retry();
        return;
    }
    [self callWebFunctionIfDefined:@"esmeOpenFeeling" withJSONArgument:feelingId completion:^(BOOL ran) {
        if (ran) {
            [EsmeModule clearPendingFeelingId:feelingId];
        } else {
            retry();
        }
    }];
}

@end
