#import "GoalsViewController.h"

#import <WebKit/WebKit.h>

static NSString *const kGoalsURL = @"https://wsl-esme-1.tailc6cd5d.ts.net/goals/";
static const NSTimeInterval kReloadAfterBackground = 30 * 60;

@interface GoalsViewController () <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) NSDate *backgroundedAt;
@end

@implementation GoalsViewController

- (UIColor *)bgColor {
    return [UIColor colorWithRed:0x1c / 255.0 green:0x11 / 255.0 blue:0x30 / 255.0 alpha:1];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [self bgColor];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = [self bgColor];
    self.webView.scrollView.backgroundColor = [self bgColor];
    // Edge to edge: the page handles safe areas itself (viewport-fit=cover).
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:self.webView];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.retryButton.frame = self.view.bounds;
    self.retryButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.retryButton.backgroundColor = [self bgColor];
    [self.retryButton setTitle:@"no connection. tap to retry." forState:UIControlStateNormal];
    [self.retryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:17];
    [self.retryButton addTarget:self action:@selector(retry) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    [self.view addSubview:self.retryButton];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];
    [self load];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)load {
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kGoalsURL]]];
}

- (void)retry {
    self.retryButton.hidden = YES;
    [self load];
}

- (void)didEnterBackground {
    self.backgroundedAt = [NSDate date];
}

- (void)willEnterForeground {
    if (self.backgroundedAt && -[self.backgroundedAt timeIntervalSinceNow] > kReloadAfterBackground) {
        [self retry];
    }
    self.backgroundedAt = nil;
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    NSString *ourHost = [NSURL URLWithString:kGoalsURL].host;
    BOOL web = [url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"];
    if (action.targetFrame.isMainFrame && web && ![url.host isEqualToString:ourHost]) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.retryButton.hidden = YES;
}

- (void)navigationFailed:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    self.retryButton.hidden = NO;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self navigationFailed:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self navigationFailed:error];
}

#pragma mark - WKUIDelegate

// target=_blank / window.open: foreign hosts go to Safari, our own host loads in place.
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)windowFeatures {
    NSURL *url = action.request.URL;
    if ([url.host isEqualToString:[NSURL URLWithString:kGoalsURL].host]) {
        [webView loadRequest:action.request];
    } else {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
    return nil;
}

@end
