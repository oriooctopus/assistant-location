#import "SessionsViewController.h"

#import <WebKit/WebKit.h>

static NSString *const kSessionsStartVoiceNotification = @"GLSessionsStartVoice";
static NSString *const kSessionsStartTextNotification = @"GLSessionsStartText";

// GLWebModuleViewController adopts WKNavigationDelegate privately in its .m,
// so its -webView:didFinishNavigation: isn't visible here; declare it so the
// override below can call super.
@interface GLWebModuleViewController (SessionsNavigationDelegate)
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
@end

@interface SessionsViewController ()
// Name of the window.<fn> mode-selection function to call once the page has
// actually finished loading. Set by -startVoice/-startText and cleared once
// flushed from -webView:didFinishNavigation: (see that method below) -- this
// replaces an earlier fixed-delay-retry design that could still race a slow
// load; -didFinishNavigation is a real "the page is loaded" signal, not a
// guess.
@property(nonatomic, copy, nullable) NSString *pendingModeFunctionName;
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

// Tries immediately (covers the page already being loaded -- the common
// case, since the More screen usually already exists) AND arms
// pendingModeFunctionName so -webView:didFinishNavigation: can retry once
// the page genuinely finishes loading, for the cold-launch race where this
// fires before session.html's own <script> has run yet.
- (void)armModeFunction:(NSString *)functionName {
    self.pendingModeFunctionName = functionName;
    [self callWebFunctionIfDefined:functionName];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [super webView:webView didFinishNavigation:navigation];
    if (self.pendingModeFunctionName) {
        [self callWebFunctionIfDefined:self.pendingModeFunctionName];
        self.pendingModeFunctionName = nil;
    }
}

@end
