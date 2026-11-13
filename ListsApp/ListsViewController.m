#import "ListsViewController.h"

#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#import "BakedConfig.h"
#import "ListsStateStore.h"

// The Lists server is tailnet-only HTTPS on this port of the same box GL_BAKED_HOST names (the
// Listen tab builds its URL the same way: https://<GL_BAKED_HOST>:<port>/). HTTPS because ATS
// blocks plain http for a bundled page's fetches and the box serves 9346 through `tailscale serve`.
static NSInteger const kListsServerPort = 9346;

// The page (web/lists.html) is bundled, so it loads with no network. It talks to this controller
// through the shared bridge protocol {id, method, params} in, window.__glReply(id, result, error) out.
// Methods: getApiToken, loadState, saveState.
// Native -> page: window.__listsOpen({listId}), window.__listsForeground().
@interface ListsViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) ListsStateStore *store;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) BOOL pageLoaded;
@property (nonatomic, strong) UIView *errorView;   // load-failure overlay (error text + Retry), built on first failure
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, copy) NSString *pendingListId; // lists://list/<id> received before the page loaded
@end

@implementation ListsViewController

- (instancetype)init {
    if ((self = [super init])) {
        _store = [[ListsStateStore alloc] init];
    }
    return self;
}

// gl-bridge.js reads window.GL_BOOT synchronously at document start to paint the themed background
// before the body parses; same boot object shape as the Gripes app (no palette yet, so the
// bridge's built-in default palette is used).
+ (NSString *)bootScriptForMode:(NSString *)mode {
    NSDictionary *boot = @{@"palette": NSNull.null, @"mode": mode, @"themeId": NSNull.null, @"platform": @"ios"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:boot options:0 error:NULL];
    return [NSString stringWithFormat:@"window.GL_BOOT = %@;", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
}

// Removes the ^ v check bar WKWebView shows above the keyboard for form fields. Only this app's
// web view: its WKContentView instance is re-classed to a runtime subclass whose inputAccessoryView is nil.
// Copied from GripesViewController.
- (void)hideInputAccessoryBar {
    UIView *content = nil;
    for (UIView *v in self.webView.scrollView.subviews) {
        if ([NSStringFromClass(v.class) hasPrefix:@"WKContent"]) { content = v; break; }
    }
    NSAssert(content, @"WKContentView not found; cannot hide the input accessory bar");
    Class base = content.class;
    NSString *name = [NSStringFromClass(base) stringByAppendingString:@"_ListsNoAccessory"];
    Class sub = NSClassFromString(name);
    if (!sub) {
        sub = objc_allocateClassPair(base, name.UTF8String, 0);
        IMP nilAccessory = imp_implementationWithBlock(^UIView *(id _self) { return nil; });
        class_addMethod(sub, @selector(inputAccessoryView), nilAccessory, "@@:");
        objc_registerClassPair(sub);
    }
    object_setClass(content, sub);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    NSString *mode = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light";
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:[ListsViewController bootScriptForMode:mode]
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
    // `lists` is the handler name of the contract. The shared gl-bridge.js (GLBridge.call) can only
    // post to `gl`, so the same handler answers both; a page may use either.
    [ucc addScriptMessageHandler:self name:@"lists"];
    [ucc addScriptMessageHandler:self name:@"gl"];
    config.userContentController = ucc;
    // The page paints its own themed background (gl-bridge.js); match it natively so any area the
    // page does not cover (overscroll, a not-yet-laid-out strip) is the same colour, never black.
    UIColor *bg = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x0d/255.0 green:0x0f/255.0 blue:0x12/255.0 alpha:1] : UIColor.whiteColor;
    }];
    self.view.backgroundColor = bg;
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    // Pinned to the view's edges (not the safe area): the page handles safe areas itself through
    // viewport-fit=cover and env(safe-area-inset-*), so the web view must reach the screen edges.
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = bg;
    self.webView.scrollView.backgroundColor = bg;
    [self.view addSubview:self.webView];
    // Page content scrolls edge to edge, so it would pass visibly under the clock / Dynamic Island.
    // An opaque strip in the page background colour covers exactly the top safe area, above the web view.
    UIView *statusStrip = [[UIView alloc] init];
    statusStrip.translatesAutoresizingMaskIntoConstraints = NO;
    statusStrip.backgroundColor = bg;
    statusStrip.userInteractionEnabled = NO;
    [self.view addSubview:statusStrip];
    [NSLayoutConstraint activateConstraints:@[
        [statusStrip.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [statusStrip.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [statusStrip.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [statusStrip.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    ]];
    [self hideInputAccessoryBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self loadPage];
}

// ---- JS -> native ----
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    NSString *ident = body[@"id"], *method = body[@"method"];
    NSDictionary *params = [body[@"params"] isKindOfClass:NSDictionary.class] ? body[@"params"] : @{};
    id result = nil;
    NSString *error = nil;
    NSError *nsError = nil;
    if ([method isEqualToString:@"getApiToken"]) {
        result = @{@"token": GL_BAKED_TOKEN,
                   @"baseUrl": [NSString stringWithFormat:@"https://%@:%ld", GL_BAKED_HOST, (long)kListsServerPort]};
    } else if ([method isEqualToString:@"loadState"]) {
        NSDictionary *state = [self.store loadStateError:&nsError];
        if (nsError) error = [NSString stringWithFormat:@"loadState failed: %@", nsError];
        else result = @{@"state": state ?: NSNull.null};
    } else if ([method isEqualToString:@"saveState"]) {
        NSDictionary *state = params[@"state"];
        if (![state isKindOfClass:NSDictionary.class]) error = [NSString stringWithFormat:@"saveState needs a state object, got %@", [state class]];
        else if ([self.store saveState:state error:&nsError]) result = @{};
        else error = [NSString stringWithFormat:@"saveState failed: %@", nsError];
    } else {
        error = [NSString stringWithFormat:@"unsupported bridge method %@", method];
    }
    if (error) NSLog(@"[Lists] %@", error);
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[ident ?: NSNull.null, result ?: NSNull.null, error ?: NSNull.null] options:0 error:NULL];
    NSString *args = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.__glReply.apply(null, %@)", args] completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[Lists] __glReply failed: %@", e);
    }];
}

// ---- native -> page ----
// `arg` is any JSON object, or nil for a call with no argument.
- (void)callPage:(NSString *)name argument:(NSDictionary *)arg {
    NSString *literal = @"";
    if (arg) literal = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:arg options:0 error:NULL] encoding:NSUTF8StringEncoding];
    NSString *js = [NSString stringWithFormat:@"window.%@(%@)", name, literal];
    [self.webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[Lists] calling %@ failed: %@", name, e);
    }];
}

- (void)openListWithId:(NSString *)listId {
    if (self.pageLoaded) [self callPage:@"__listsOpen" argument:@{@"listId": listId}];
    else self.pendingListId = listId; // cold launch via the widget: delivered once the page has loaded
}

- (void)appDidForeground {
    // Before the first load there is nothing to refresh; the page loads its state on its own start.
    if (self.pageLoaded) [self callPage:@"__listsForeground" argument:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageLoaded = YES;
    if (self.pendingListId) {
        NSString *listId = self.pendingListId;
        self.pendingListId = nil;
        [self callPage:@"__listsOpen" argument:@{@"listId": listId}];
    }
}

// A failed load must never leave a blank screen: the error text and a Retry button cover the web view.
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self showLoadError:error];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self showLoadError:error];
}

- (void)showLoadError:(NSError *)error {
    NSLog(@"[Lists] page load failed: %@", error);
    self.pageLoaded = NO;
    if (!self.errorView) {
        UILabel *label = [[UILabel alloc] init];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.labelColor;
        label.font = [UIFont systemFontOfSize:14];
        UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
        [retry setTitle:@"Retry" forState:UIControlStateNormal];
        retry.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [retry addTarget:self action:@selector(retryLoad) forControlEvents:UIControlEventTouchUpInside];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, retry]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 16;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = self.view.backgroundColor;
        [overlay addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:24],
            [stack.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-24],
        ]];
        self.errorLabel = label;
        self.errorView = overlay;
    }
    self.errorLabel.text = [NSString stringWithFormat:@"Could not load the page\n%@", error];
    [self.view addSubview:self.errorView];
}

- (void)retryLoad {
    [self.errorView removeFromSuperview];
    [self loadPage];
}

- (void)loadPage {
    NSURL *page = [NSBundle.mainBundle URLForResource:@"lists" withExtension:@"html"];
    NSAssert(page, @"lists.html missing from the app bundle");
    [self.webView loadFileURL:page allowingReadAccessToURL:NSBundle.mainBundle.resourceURL];
}

@end
