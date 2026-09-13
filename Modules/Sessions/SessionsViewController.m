#import "SessionsViewController.h"

#import <WebKit/WebKit.h>

static NSString *const kSessionsStartVoiceNotification = @"GLSessionsStartVoice";
static NSString *const kSessionsStartTextNotification = @"GLSessionsStartText";
NSString *const kSessionsAttachNotification = @"GLSessionsAttach";
NSString *const kSessionsAttachIDsKey = @"ids";

// GLWebModuleViewController adopts WKNavigationDelegate privately in its .m,
// so its -webView:didFinishNavigation: isn't visible here; declare it so the
// override below can call super.
@interface GLWebModuleViewController (SessionsNavigationDelegate)
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
@end

// A pending call takes the completion it must report `ran` to -- see
// -enqueueJSCall: below for why this isn't a plain no-argument block.
typedef void (^GLSessionsPendingCall)(void (^completion)(BOOL ran));

@interface SessionsViewController ()
// Queue of pending page-function calls (mode selection, then attachment
// ids, in the order they were armed). Tried immediately when armed (covers
// the page already being loaded -- the common case, since the More screen
// usually already exists) AND replayed from -webView:didFinishNavigation:
// for the cold-launch race where the URL arrives before session.html's own
// <script> has run yet -- this replaces the old single
// `pendingModeFunctionName` scalar (a fixed-delay-retry design predates
// even that) now that a deep link can carry both a mode AND an attachment
// list. -didFinishNavigation is a real "the page is loaded" signal, not a
// guess.
//
// A call is removed from this queue the moment it actually RUNS (its
// `ran` completion fires YES) rather than unconditionally after one replay:
// without that, a call armed once (say, on the cold-launch openurl) would
// keep re-firing on every LATER navigation of this same page instance --
// pull-to-refresh, a theme-driven -pushThemeToPageOrReload reload -- each
// one replaying every call still sitting in the queue and duplicating the
// attach/mode action on the page.
@property(nonatomic, strong, nullable) NSMutableArray<GLSessionsPendingCall> *pendingJSCalls;
@end

@implementation SessionsViewController

// Observers go in the DESIGNATED initializer (every init path, including
// -initWithManagedPageNamed:, chains through it), not -viewDidLoad:
// +moduleHandleURL: posts the mode notification right after an animated
// push, and UIKit may not load the view until the transition runs, so a
// -viewDidLoad observer can miss it. Every module's +makeViewController runs
// at launch, so this is alive before any deep link arrives.
- (instancetype)initWithURL:(NSURL *)url displayName:(NSString *)displayName {
    self = [super initWithURL:url displayName:displayName];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(startVoice)
                                                     name:kSessionsStartVoiceNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(startText)
                                                     name:kSessionsStartTextNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(attachIDsReceived:)
                                                     name:kSessionsAttachNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)startVoice {
    [self armModeFunction:@"window.startVoiceMode"];
}

- (void)startText {
    [self armModeFunction:@"window.focusTextMode"];
}

- (void)attachIDsReceived:(NSNotification *)notification {
    NSArray<NSString *> *ids = notification.userInfo[kSessionsAttachIDsKey];
    if (ids.count == 0) return;
    [self armAddAttachments:ids];
}

// Enqueues the call AND tries it immediately -- see the pendingJSCalls doc
// comment above for why both.
- (void)armModeFunction:(NSString *)functionName {
    __weak __typeof(self) weakSelf = self;
    [self enqueueJSCall:^(void (^completion)(BOOL ran)) {
        [weakSelf callWebFunctionIfDefined:functionName completion:completion];
    }];
}

// SessionsModule.m's +moduleHandleURL: validates the ids against the uuid.ext
// pattern before this ever runs, so no further validation happens here --
// this just forwards the already-clean list into the page contract
// (window.addAttachments(ids)).
- (void)armAddAttachments:(NSArray<NSString *> *)ids {
    __weak __typeof(self) weakSelf = self;
    [self enqueueJSCall:^(void (^completion)(BOOL ran)) {
        [weakSelf callWebFunctionIfDefined:@"addAttachments" withJSONArgument:ids completion:completion];
    }];
}

// Adds `call` to the queue, then runs it right away. `call` reports back
// via its own completion whether it actually ran (the page had the function
// defined) -- on YES, the exact same call object is removed from the queue
// (default block -isEqual: is pointer identity, and `call` here is that
// same instance), so a later navigation's replay in
// -webView:didFinishNavigation: only ever re-attempts calls that never
// successfully ran.
- (void)enqueueJSCall:(GLSessionsPendingCall)call {
    if (!self.pendingJSCalls) {
        self.pendingJSCalls = [NSMutableArray array];
    }
    GLSessionsPendingCall queued = [call copy];
    [self.pendingJSCalls addObject:queued];
    [self attemptPendingCall:queued];
}

- (void)attemptPendingCall:(GLSessionsPendingCall)call {
    __weak __typeof(self) weakSelf = self;
    call(^(BOOL ran) {
        if (!ran) return;
        [weakSelf.pendingJSCalls removeObject:call];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [super webView:webView didFinishNavigation:navigation];
    // Snapshot before replaying: a call's own completion above mutates
    // pendingJSCalls (removing itself on success), so iterating the live
    // array while its contents change under us is exactly the bug this
    // whole queue exists to avoid.
    NSArray<GLSessionsPendingCall> *calls = [self.pendingJSCalls copy];
    for (GLSessionsPendingCall call in calls) {
        [self attemptPendingCall:call];
    }
}

@end
