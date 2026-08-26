#import "GLWebModuleViewController.h"

#import <WebKit/WebKit.h>

#import "GLTheme.h"

@interface GLWebModuleViewController () <WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, strong, nullable) NSURL *backingURL;
@property(nonatomic, copy, nullable) NSString *backingDisplayName;

@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property(nonatomic, strong) UIView *errorView;
@property(nonatomic, strong) UILabel *errorLabel;
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

    [self loadPage];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Theme propagation

- (WKUserContentController *)makeUserContentController {
    WKUserContentController *controller = [[WKUserContentController alloc] init];
    NSString *source = [NSString stringWithFormat:
        @"document.documentElement.dataset.theme = %@;",
        [self javaScriptStringLiteralForModeName:[GLTheme effectiveModeName]]];
    WKUserScript *script =
        [[WKUserScript alloc] initWithSource:source
                                injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                             forMainFrameOnly:YES];
    [controller addUserScript:script];
    return controller;
}

- (NSString *)javaScriptStringLiteralForModeName:(NSString *)modeName {
    return [NSString stringWithFormat:@"\"%@\"", modeName];
}

- (NSURL *)themedWebURL {
    NSURL *url = [self webURL];
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"theme" value:[GLTheme effectiveModeName]]];
    components.queryItems = items;
    return components.URL;
}

- (void)themeDidChange {
    // The injected script only sets data-theme at document start, and the
    // query param is baked into the URL — both need a fresh navigation to
    // pick up a mode flip that happens while the page is already loaded.
    [self loadPage];
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
    NSURL *url = [self themedWebURL];
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)reloadTapped {
    [self loadPage];
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
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        NSURL *url = navigationAction.request.URL;
        NSString *scheme = url.scheme.lowercaseString;
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
    [self showErrorWithMessage:
        [NSString stringWithFormat:@"Couldn't reach %@ at %@.\n\n"
                                     "Check that you're on the tailnet and the "
                                     "server is running.\n\n%@",
                                    [self displayName], [self webURL], error.localizedDescription]];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
             withError:(NSError *)error {
    [self.loadingIndicator stopAnimating];
    [self.refreshControl endRefreshing];
    [self showErrorWithMessage:
        [NSString stringWithFormat:@"Lost connection to %@ at %@.\n\n%@",
                                    [self displayName], [self webURL], error.localizedDescription]];
}

@end
