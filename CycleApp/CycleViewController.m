#import "CycleViewController.h"

#import <WebKit/WebKit.h>

#import "CycleBridge.h"

@interface CycleViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) CycleBridge *bridge;
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation CycleViewController

- (instancetype)initWithBridge:(CycleBridge *)bridge {
    if ((self = [super init])) _bridge = bridge;
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"cycle"];
    config.userContentController = ucc;

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.blackColor;
    self.webView.allowsLinkPreview = NO;
    UIScrollView *scroll = self.webView.scrollView;
    scroll.backgroundColor = UIColor.blackColor;
    // The page handles safe areas itself (viewport-fit=cover, env(safe-area-inset-*)).
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scroll.bounces = NO;
    scroll.alwaysBounceVertical = NO;
    scroll.alwaysBounceHorizontal = NO;
    scroll.minimumZoomScale = 1;
    scroll.maximumZoomScale = 1;
    scroll.pinchGestureRecognizer.enabled = NO;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    self.bridge.presentFile = ^(NSURL *url) {
        UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        // iPad needs an anchor; harmless on iPhone.
        sheet.popoverPresentationController.sourceView = weakSelf.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(weakSelf.view.bounds), CGRectGetMaxY(weakSelf.view.bounds), 0, 0);
        [weakSelf presentViewController:sheet animated:YES completion:nil];
    };
    self.bridge.evaluateJS = ^(NSString *js) {
        [weakSelf.webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
            if (e) NSLog(@"[Cycle] script failed: %@\n%@", e, js);
        }];
    };

    // `web` is a folder reference, so it keeps its directory in the bundle.
    NSURL *page = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html" subdirectory:@"web"];
    NSAssert(page, @"web/index.html missing from the app bundle");
    [self.webView loadFileURL:page allowingReadAccessToURL:NSBundle.mainBundle.resourceURL];
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.bridge handleMessage:message.body];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self.bridge pageWillReload];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[Cycle] page navigation failed: %@", error);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[Cycle] page load failed: %@", error);
}

@end
