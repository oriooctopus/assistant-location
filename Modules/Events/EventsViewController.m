#import "EventsViewController.h"

#import <WebKit/WebKit.h>

// Same tailnet-IP style as GL_BAKED_BASE_URL in BakedConfig.h (rather than
// the wsl-esme-1.tailc6cd5d.ts.net hostname), for consistency with the rest
// of the app's baked config.
static NSString *const kEventsURLString = @"http://100.103.237.24:8304/";

// Matches the web app's dark background so there's no white flash while the
// page loads.
static CGFloat const kBackgroundR = 0x0d / 255.0;
static CGFloat const kBackgroundG = 0x0f / 255.0;
static CGFloat const kBackgroundB = 0x12 / 255.0;

@interface EventsViewController () <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIView *errorView;
@property(nonatomic, strong) UILabel *errorLabel;
@end

@implementation EventsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    UIColor *background = [UIColor colorWithRed:kBackgroundR
                                           green:kBackgroundG
                                            blue:kBackgroundB
                                           alpha:1.0];
    self.view.backgroundColor = background;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
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
    self.refreshControl.tintColor = UIColor.whiteColor;
    [self.refreshControl addTarget:self
                             action:@selector(reloadTapped)
                   forControlEvents:UIControlEventValueChanged];
    [self.webView.scrollView addSubview:self.refreshControl];

    [self buildErrorView:background];
    [self loadEvents];
}

#pragma mark - Error view

- (void)buildErrorView:(UIColor *)background {
    self.errorView = [[UIView alloc] init];
    self.errorView.backgroundColor = background;
    self.errorView.hidden = YES;
    self.errorView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.errorView];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.textColor = UIColor.whiteColor;
    self.errorLabel.font = [UIFont systemFontOfSize:15];
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    retryButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [retryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    retryButton.backgroundColor = UIColor.systemBlueColor;
    retryButton.layer.cornerRadius = 10;
    [retryButton.heightAnchor constraintEqualToConstant:44].active = YES;
    [retryButton addTarget:self
                     action:@selector(reloadTapped)
           forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.errorLabel, retryButton
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
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
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor constant:32],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor constant:-32],
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

- (void)loadEvents {
    [self hideError];
    NSURL *url = [NSURL URLWithString:kEventsURLString];
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)reloadTapped {
    [self loadEvents];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self hideError];
    [self.refreshControl endRefreshing];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    [self.refreshControl endRefreshing];
    [self showErrorWithMessage:
        [NSString stringWithFormat:@"Couldn't reach the event finder at %@.\n\n"
                                     "Check that you're on the tailnet and the "
                                     "server is running.\n\n%@",
                                    kEventsURLString, error.localizedDescription]];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
             withError:(NSError *)error {
    [self.refreshControl endRefreshing];
    [self showErrorWithMessage:
        [NSString stringWithFormat:@"Lost connection to the event finder at %@.\n\n%@",
                                    kEventsURLString, error.localizedDescription]];
}

@end
