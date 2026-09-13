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

@interface SessionsViewController ()
// Queue of no-argument blocks, each one a single page-function call (mode
// selection, then attachment ids, in the order they were armed). Tried
// immediately when armed (covers the page already being loaded -- the
// common case, since the More screen usually already exists) AND replayed
// in full from -webView:didFinishNavigation: for the cold-launch race where
// the URL arrives before session.html's own <script> has run yet -- this
// replaces the old single `pendingModeFunctionName` scalar (a fixed-delay
// -retry design predates even that) now that a deep link can carry both a
// mode AND an attachment list. -didFinishNavigation is a real "the page is
// loaded" signal, not a guess.
@property(nonatomic, strong, nullable) NSMutableArray<void (^)(void)> *pendingJSCalls;
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
    [self enqueueJSCall:^{
        [weakSelf callWebFunctionIfDefined:functionName];
    }];
}

// SessionsModule.m's +moduleHandleURL: validates the ids against the uuid.ext
// pattern before this ever runs, so no further validation happens here --
// this just forwards the already-clean list into the page contract
// (window.addAttachments(ids)).
- (void)armAddAttachments:(NSArray<NSString *> *)ids {
    __weak __typeof(self) weakSelf = self;
    [self enqueueJSCall:^{
        [weakSelf callWebFunctionIfDefined:@"addAttachments" withJSONArgument:ids];
    }];
}

- (void)enqueueJSCall:(void (^)(void))call {
    if (!self.pendingJSCalls) {
        self.pendingJSCalls = [NSMutableArray array];
    }
    [self.pendingJSCalls addObject:[call copy]];
    call();
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [super webView:webView didFinishNavigation:navigation];
    if (self.pendingJSCalls.count > 0) {
        NSArray<void (^)(void)> *calls = [self.pendingJSCalls copy];
        self.pendingJSCalls = nil;
        for (void (^call)(void) in calls) {
            call();
        }
    }
}

@end
