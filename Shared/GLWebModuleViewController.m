#import "GLWebModuleViewController.h"

#import <WebKit/WebKit.h>

#import "GLTheme.h"
#import "GLWebBridge.h"

@interface GLWebModuleViewController () <WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, strong, nullable) NSURL *backingURL;
@property(nonatomic, copy, nullable) NSString *backingDisplayName;

@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property(nonatomic, strong) UIView *errorView;
@property(nonatomic, strong) UILabel *errorLabel;
@property(nonatomic, strong) GLWebBridge *bridge;
@end

@implementation GLWebModuleViewController

- (instancetype)initWithURL:(NSURL *)url displayName:(NSString *)displayName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _backingURL = url;
        _backingDisplayName = [displayName copy];
    }
    return self;
}

- (instancetype)initWithBundledPageNamed:(NSString *)pageName {
    NSString *resourceName = [pageName stringByDeletingPathExtension];
    NSString *extension = [pageName pathExtension];
    NSBundle *bundle = [NSBundle mainBundle];
    // Modules/ is a PBXFileSystemSynchronizedRootGroup (see MODULES.md); the
    // pages under Modules/WebPages/ may land flat in the bundle root or
    // nested under a "WebPages" subdirectory depending on how Xcode's
    // synchronized-group resource copying resolves that folder -- there is
    // no compiler on the box that wrote this to settle it, so both are
    // tried before raising.
    NSURL *fileURL = [bundle URLForResource:resourceName withExtension:extension subdirectory:@"WebPages"];
    if (!fileURL) {
        fileURL = [bundle URLForResource:resourceName withExtension:extension];
    }
    if (!fileURL) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Bundled web page \"%@\" not found in the app bundle (checked "
                            "WebPages/ and the bundle root) -- check that Modules/'s "
                            "file-system-synchronized group is copying .html resources "
                            "into the build product", pageName];
    }
    return [self initWithURL:fileURL displayName:pageName];
}

- (NSURL *)webURL {
    if (!self.backingURL) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"%@ has no URL — either use -initWithURL:displayName: or override -webURL",
                           NSStringFromClass(self.class)];
    }
    return self.backingURL;
}

- (NSString *)displayName {
    if (!self.backingDisplayName) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"%@ has no display name — either use -initWithURL:displayName: or override -displayName",
                           NSStringFromClass(self.class)];
    }
    return self.backingDisplayName;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    UIColor *background = [GLTheme backgroundColor];
    self.view.backgroundColor = background;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.userContentController = [self makeUserContentController];

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = background;
    self.webView.scrollView.backgroundColor = background;
    // A swipeable card deck fights vertical rubber-banding, so only allow
    // horizontal bounce (harmless, and iOS ties the two together loosely).
    self.webView.scrollView.bounces = NO;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
    ]];

    // The page is a long-lived SPA (background searches, swipe state) — give
    // it an explicit reload affordance rather than relying on re-navigation.
    self.refreshControl = [[UIRefreshControl alloc] init];
    // Sits over the adaptive GLTheme.backgroundColor, not a fixed dark
    // surface — white was invisible in light mode. textSecondaryColor
    // reads as a muted spinner in both themes.
    self.refreshControl.tintColor = [GLTheme textSecondaryColor];
    [self.refreshControl addTarget:self
                             action:@selector(reloadTapped)
                   forControlEvents:UIControlEventValueChanged];
    [self.webView.scrollView addSubview:self.refreshControl];

    self.loadingIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingIndicator.hidesWhenStopped = YES;
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.loadingIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor],
    ]];

    [self buildErrorView:background];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(themeDidChange)
                                                  name:GLThemeDidChangeNotification
                                                object:nil];
    // Distinct trigger from the mode flip above -- see GLTheme.h's doc
    // comment on GLPaletteDidChangeNotification for why a palette change
    // (new theme id, or the same id resolving differently) needs its own
    // notification rather than piggybacking on GLThemeDidChangeNotification.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(paletteDidChange)
                                                  name:GLPaletteDidChangeNotification
                                                object:nil];

    [self loadPage];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Theme propagation

// Built once at -viewDidLoad: only the "gl" bridge handler, which must be
// added exactly once per WKUserContentController (a second
// addScriptMessageHandler:name: for the same name throws). The boot script
// itself is NOT added here -- see -installBootUserScript, called from
// -loadPage on every load, which is what actually carries the current
// palette/mode/themeId (this used to be built once here and go stale the
// moment either changed after the first load).
- (WKUserContentController *)makeUserContentController {
    WKUserContentController *controller = [[WKUserContentController alloc] init];
    self.bridge = [[GLWebBridge alloc] initWithHostViewController:self];
    [controller addScriptMessageHandler:self.bridge name:@"gl"];
    return controller;
}

- (NSString *)javaScriptStringLiteralForModeName:(NSString *)modeName {
    return [NSString stringWithFormat:@"\"%@\"", modeName];
}

// Rebuilt on EVERY -loadPage (removeAllUserScripts + re-add), not just once
// at -viewDidLoad: a WKUserScript is immutable once created, so a stale one
// left in place across a mode/palette change would keep injecting the OLD
// GL_BOOT into every subsequent navigation (including the retry reload
// -loadPage itself triggers).
- (void)installBootUserScript {
    WKUserContentController *controller = self.webView.configuration.userContentController;
    [controller removeAllUserScripts];
    WKUserScript *script =
        [[WKUserScript alloc] initWithSource:[self bootScriptSource]
                                injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                             forMainFrameOnly:YES];
    [controller addUserScript:script];
}

// `window.GL_BOOT = {palette, mode, themeId, platform}` + the legacy
// `document.documentElement.dataset.theme` assignment -- the frozen
// native<->web bridge protocol's boot injection (Modules/WebBridge/
// GLWebBridge.h). NSJSONSerialization builds the object literal so nothing
// here ever string-formats palette/theme-id content directly into the
// script.
- (NSString *)bootScriptSource {
    NSString *mode = [GLTheme effectiveModeName];
    NSDictionary *palette = [GLTheme currentPaletteColors];
    NSString *themeId = [GLTheme selectedThemeId];

    NSDictionary *boot = @{
        @"palette": palette ?: [NSNull null],
        @"mode": mode,
        @"themeId": themeId ?: [NSNull null],
        @"platform": @"ios",
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:boot options:0 error:&error];
    NSString *bootJSON = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                              : @"{\"palette\":null,\"mode\":\"light\",\"themeId\":null,\"platform\":\"ios\"}";
    return [NSString stringWithFormat:@"window.GL_BOOT = %@;\ndocument.documentElement.dataset.theme = %@;",
                                       bootJSON, [self javaScriptStringLiteralForModeName:mode]];
}

- (NSURL *)themedWebURL {
    NSURL *url = [self webURL];
    // Bundled pages carry their theme entirely through GL_BOOT (see
    // -bootScriptSource) -- mutating a file:// URL's query string buys
    // nothing (there's no server on the other end to read it) and risks
    // NSURLComponents mangling a file URL some iOS versions round-trip
    // imperfectly.
    if (url.isFileURL) return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"theme" value:[GLTheme effectiveModeName]]];
    components.queryItems = items;
    return components.URL;
}

// Updates the wrapper's OWN chrome (the parts UIKit draws, not the page) --
// called from both -themeDidChange and -paletteDidChange, since either can
// change these independent of the other.
- (void)updateChromeForTheme {
    UIColor *background = [GLTheme backgroundColor];
    self.view.backgroundColor = background;
    self.webView.backgroundColor = background;
    self.webView.scrollView.backgroundColor = background;
    self.refreshControl.tintColor = [GLTheme textSecondaryColor];
}

- (void)themeDidChange {
    [self updateChromeForTheme];
    [self pushThemeToPageOrReload];
}

- (void)paletteDidChange {
    [self updateChromeForTheme];
    [self pushThemeToPageOrReload];
}

// Live-pushes the new palette/mode/themeId into the already-loaded page via
// `window.__glThemeChanged`, guarded so a page that never defines it (or
// hasn't finished loading gl-bridge.js yet) is simply a no-op rather than a
// thrown exception. A full -loadPage reload happens ONLY when the page never
// successfully loaded in the first place (the error view is showing): there
// is nothing live to push a theme into, and a reload is also the one way to
// retry the load itself.
- (void)pushThemeToPageOrReload {
    if (!self.errorView.hidden) {
        [self loadPage];
        return;
    }

    NSDictionary *payload = @{
        @"palette": [GLTheme currentPaletteColors] ?: [NSNull null],
        @"mode": [GLTheme effectiveModeName],
        @"themeId": [GLTheme selectedThemeId] ?: [NSNull null],
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"typeof window.__glThemeChanged === 'function' && window.__glThemeChanged(%@);", json];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

#pragma mark - Error view

- (void)buildErrorView:(UIColor *)background {
    self.errorView = [[UIView alloc] init];
    self.errorView.backgroundColor = background;
    self.errorView.hidden = YES;
    self.errorView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.errorView];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.textColor = [GLTheme textPrimaryColor];
    self.errorLabel.font = [GLTheme bodyFont];
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    retryButton.titleLabel.font = [GLTheme buttonFont];
    [retryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    retryButton.backgroundColor = [GLTheme accentColor];
    retryButton.layer.cornerRadius = [GLTheme cornerRadius];
    [retryButton.heightAnchor constraintEqualToConstant:[GLTheme controlHeight]].active = YES;
    [retryButton addTarget:self
                     action:@selector(reloadTapped)
           forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.errorLabel, retryButton
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = [GLTheme spacingL];
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.errorView addSubview:stack];

    UILayoutGuide *guide = self.errorView.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.errorView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.errorView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.errorView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.errorView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor
                                                          constant:[GLTheme spacingL]],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor
                                                         constant:-[GLTheme spacingL]],
    ]];
}

- (void)showErrorWithMessage:(NSString *)message {
    self.errorLabel.text = message;
    self.errorView.hidden = NO;
    [self.webView setHidden:YES];
}

- (void)hideError {
    self.errorView.hidden = YES;
    self.webView.hidden = NO;
}

#pragma mark - Loading

- (void)loadPage {
    [self hideError];
    [self.loadingIndicator startAnimating];
    [self installBootUserScript];
    NSURL *url = [self themedWebURL];
    if (url.isFileURL) {
        [self.webView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
    } else {
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

- (void)reloadTapped {
    [self loadPage];
}

#pragma mark - Test hook

- (void)evaluateTestJavaScript:(NSString *)script
              completionHandler:(void (^)(id _Nullable, NSError *_Nullable))completionHandler {
    [self.webView evaluateJavaScript:script completionHandler:completionHandler];
}

#pragma mark - WKUIDelegate

// target="_blank" (and window.open) ask for a new WKWebView; we don't host a
// second web view, so hand the URL to Safari instead of silently dropping it.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!navigationAction.targetFrame || !navigationAction.targetFrame.isMainFrame) {
        NSURL *url = navigationAction.request.URL;
        if (url) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }
    }
    return nil;
}

#pragma mark - WKNavigationDelegate

// Keep plain link taps inside the SPA (so it doesn't get navigated away from
// under itself), but send anything pointing off-host — or a non-http(s)
// scheme like mailto:/tel: — out to Safari/the system instead.
//
// file:// is exempt from all of this: it is inherently local (there is no
// "off-host" for a bundled page) and routing it to
// UIApplication.openURL:options:completionHandler: would just fail silently
// (Safari can't open an app-bundle file URL), cancelling a same-page
// in-content link a bundled page might use. The initial loadFileURL:
// navigation that opens the page in the first place is WKNavigationTypeOther,
// not LinkActivated, so it never even reaches this branch.
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        NSURL *url = navigationAction.request.URL;
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"file"]) {
            decisionHandler(WKNavigationActionPolicyAllow);
            return;
        }
        BOOL isHTTPFamily = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
        BOOL sameHost = isHTTPFamily && [url.host isEqualToString:[self webURL].host];
        if (!sameHost) {
            if (url) {
                [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            }
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self hideError];
    [self.loadingIndicator stopAnimating];
    [self.refreshControl endRefreshing];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    [self.loadingIndicator stopAnimating];
    [self.refreshControl endRefreshing];
    [self showErrorWithMessage:[self unreachableMessageForError:error initialLoad:YES]];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
             withError:(NSError *)error {
    [self.loadingIndicator stopAnimating];
    [self.refreshControl endRefreshing];
    [self showErrorWithMessage:[self unreachableMessageForError:error initialLoad:NO]];
}

// A bundled (file://) page's load can't fail because "you're not on the
// tailnet" -- that copy is specific to the HTTP(S) pages this class also
// wraps (Events, Todos, Journal's Recent-recordings page), and would be
// actively misleading for a page that never touched the network at all.
- (NSString *)unreachableMessageForError:(NSError *)error initialLoad:(BOOL)initialLoad {
    if ([self webURL].isFileURL) {
        return [NSString stringWithFormat:@"Couldn't load %@.\n\n%@",
                                           [self displayName], error.localizedDescription];
    }
    NSString *verb = initialLoad ? @"Couldn't reach" : @"Lost connection to";
    return [NSString stringWithFormat:@"%@ %@ at %@.\n\n"
                                        "Check that you're on the tailnet and the "
                                        "server is running.\n\n%@",
                                       verb, [self displayName], [self webURL], error.localizedDescription];
}

@end
