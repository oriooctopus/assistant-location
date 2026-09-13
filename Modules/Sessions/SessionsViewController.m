#import "SessionsViewController.h"

static NSString *const kSessionsStartVoiceNotification = @"GLSessionsStartVoice";
static NSString *const kSessionsStartTextNotification = @"GLSessionsStartText";

@implementation SessionsViewController

- (instancetype)initWithManagedPageNamed:(NSString *)pageName {
    self = [super initWithManagedPageNamed:pageName];
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
    [self callModeFunction:@"window.startVoiceMode"];
}

- (void)startText {
    [self callModeFunction:@"window.focusTextMode"];
}

// -callWebFunctionIfDefined: is a silent no-op if session.html's own
// <script> (which defines window.startVoiceMode/focusTextMode -- see that
// file) hasn't run yet, e.g. this VC was just built and its WKWebView is
// mid-load when the Control Center tap arrives (cold launch: the overflow
// module list, this VC included, is constructed once at app start per
// GLModuleRegistry, but "constructed" isn't "page loaded"). There's no
// public "page finished loading" hook on GLWebModuleViewController to
// retry off of, so this retries on a short fixed delay instead -- crude,
// but the page is a small bundled/cached file with no network round trip
// on the critical path, so by ~400ms it's essentially always ready. A
// missed call here just means the phone lands on the page without voice/
// text auto-focused, not a crash or a stuck state either way.
- (void)callModeFunction:(NSString *)functionName {
    [self callWebFunctionIfDefined:functionName];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self callWebFunctionIfDefined:functionName];
    });
}

@end
