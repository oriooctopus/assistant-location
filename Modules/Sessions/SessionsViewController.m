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

// -viewDidLoad, not an overridden initializer: -initWithManagedPageNamed: is
// a CONVENIENCE initializer implemented on the base class (its real
// designated initializer is -initWithURL:displayName:, see
// GLWebModuleViewController.h) -- overriding a convenience initializer to
// bolt on side effects is fragile (it silently stops running if a future
// caller reaches this class through a different initializer path). Every
// module's +makeViewController runs at launch, well before
// SessionsModule's +moduleHandleURL: could possibly fire a notification
// (same ordering guarantee EsmeViewController's own -init comment
// documents), and -viewDidLoad runs the first time this view controller's
// view is accessed -- which for an overflow module is exactly when
// GLModuleRegistry's +openOverflowModuleWithIdentifier: (called from
// +moduleHandleURL: just before it posts the notification) pushes this
// controller onto the More nav stack. So the observer is guaranteed alive
// before the notification that would use it, same guarantee, safer hook.
- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(startVoice)
                                                   name:kSessionsStartVoiceNotification
                                                 object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(startText)
                                                   name:kSessionsStartTextNotification
                                                 object:nil];
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
