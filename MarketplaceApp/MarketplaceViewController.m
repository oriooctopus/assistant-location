#import "MarketplaceViewController.h"

#import <WebKit/WebKit.h>

#import "BakedConfig.h"
#import "GLWebPageCache.h"

// The page is Modules/WebPages/questions.html, a managed page: the bundled copy is
// the offline floor, and GLWebPageCache swaps in a newer verified copy published by
// events/server.py (/webpages/*) for the next load. It talks to the native side through two bridge calls
// (getApiToken, goBack) which the main app answers via GLWebBridge; here a
// minimal message handler answers them.
@interface MarketplaceViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) BOOL pageLoaded;
@property (nonatomic, copy) NSDictionary *pendingRef;
@end

@implementation MarketplaceViewController

+ (NSString *)bootScriptForMode:(NSString *)mode {
    NSDictionary *boot = @{
        @"palette": NSNull.null, @"mode": mode, @"themeId": NSNull.null, @"platform": @"ios",
        @"apiBase": [NSString stringWithFormat:@"http://%@:8324", GL_BAKED_HOST],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:boot options:0 error:NULL];
    NSString *bootJSON = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    // The page posts replies to the endpoint the main-app server stamps on each question
    // ('/push/reply'); this app's server exposes '/reply' instead, so the fetch is remapped
    // here rather than editing the shared page. 'Back' has nothing to go back to in a
    // standalone app, so it is hidden on the list (the answer view still uses it).
    return [NSString stringWithFormat:
        @"window.GL_BOOT = %@;\n"
        @"(function () {\n"
        @"  var realFetch = window.fetch;\n"
        @"  window.fetch = function (url, opts) {\n"
        @"    if (typeof url === 'string' && url.slice(-11) === '/push/reply') url = url.slice(0, -11) + '/reply';\n"
        @"    return realFetch.call(this, url, opts);\n"
        @"  };\n"
        @"})();\n"
        @"document.addEventListener('DOMContentLoaded', function () {\n"
        @"  var s = document.createElement('style');\n"
        @"  s.textContent = 'body[data-list=\"1\"] #q-back { visibility: hidden; }';\n"
        @"  document.head.appendChild(s);\n"
        @"  var title = document.getElementById('q-header-title');\n"
        @"  function sync() { document.body.dataset.list = title.textContent === 'Facebook' ? '1' : '0'; }\n"
        @"  sync();\n"
        @"  new MutationObserver(sync).observe(title, { childList: true, characterData: true, subtree: true });\n"
        @"});\n",
        bootJSON];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:[MarketplaceViewController bootScriptForMode:self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light"]
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
    [ucc addScriptMessageHandler:self name:@"gl"];
    config.userContentController = ucc;
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.backgroundColor = UIColor.systemBackgroundColor;
    [self.view addSubview:self.webView];

    [self loadPage];
    [self checkForPageUpdate];
}

// Loads the best available copy: the verified server set if one is cached, else the bundle.
- (void)loadPage {
    NSURL *page = [GLWebPageCacheActiveDirectory() URLByAppendingPathComponent:@"questions.html"];
    NSAssert([NSFileManager.defaultManager fileExistsAtPath:page.path], @"questions.html missing at %@", page);
    self.pageLoaded = NO;
    [self.webView loadFileURL:page allowingReadAccessToURL:page.URLByDeletingLastPathComponent];
}

// Background check; a newly promoted set is loaded straight away.
- (void)checkForPageUpdate {
    GLWebPageCacheCheckForUpdates(^(BOOL updated) {
        if (updated) [self loadPage];
    });
}

// ---- JS -> native (the page's GLBridge.call protocol) ----
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    NSString *ident = body[@"id"], *method = body[@"method"];
    id result = nil;
    NSString *error = nil;
    if ([method isEqualToString:@"getApiToken"]) {
        result = @{@"token": GL_BAKED_TOKEN};
    } else if ([method isEqualToString:@"goBack"]) {
        result = @{};
    } else {
        error = [NSString stringWithFormat:@"unsupported bridge method %@", method];
        NSLog(@"[Marketplace] %@", error);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[ident ?: NSNull.null, result ?: NSNull.null, error ?: NSNull.null] options:0 error:NULL];
    NSString *args = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    // args is a JSON array literal "[id,result,error]"; spread it into the call.
    [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.__glReply.apply(null, %@)", args] completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[Marketplace] __glReply failed: %@", e);
    }];
}

// ---- native -> page ----
- (void)callPageFunction:(NSString *)name argument:(NSDictionary *)arg completion:(void (^)(BOOL ran))completion {
    NSString *argLiteral = @"";
    if (arg) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:arg options:0 error:NULL];
        argLiteral = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    }
    NSString *js = [NSString stringWithFormat:@"(typeof window.%@ === 'function') ? (window.%@(%@), true) : false", name, name, argLiteral];
    [self.webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error) NSLog(@"[Marketplace] calling %@ failed: %@", name, error);
        if (completion) completion(!error && [result boolValue]);
    }];
}

- (void)deliverPendingRef {
    NSDictionary *ref = self.pendingRef;
    if (!ref || !self.pageLoaded) return;
    [self callPageFunction:@"openQuestion" argument:ref completion:^(BOOL ran) {
        if (ran && self.pendingRef == ref) self.pendingRef = nil;
    }];
}

- (void)openQuestionWithListing:(NSString *)listing buyer:(NSString *)buyer {
    self.pendingRef = @{@"listing": listing ?: @"", @"buyer": buyer ?: @""};
    [self deliverPendingRef];
}

- (void)refresh {
    [self checkForPageUpdate];
    if (self.pageLoaded) [self callPageFunction:@"refreshQuestions" argument:nil completion:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageLoaded = YES;
    [self deliverPendingRef];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[Marketplace] page navigation failed: %@", error);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[Marketplace] page load failed: %@", error);
}

@end
