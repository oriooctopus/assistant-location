#import "GripesViewController.h"

#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#import "BakedConfig.h"
#import "GripesStore.h"
#import "GripesVoiceListener.h"

// The page (web/gripes.html) is bundled, so it loads with no network. It talks to this controller
// through the shared `gl` bridge protocol: {id, method, params} in, window.__glReply(id, result,
// error) out. Methods: getApiToken, loadEntries, upsertEntry, startVoice, stopVoice.
// Native -> page calls: gripesVoice({type,text|message}), gripesOpenLog(), gripesEntriesChanged().
@interface GripesViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) GripesStore *store;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) GripesVoiceListener *voice;
@property (nonatomic, assign) BOOL pageLoaded;
@property (nonatomic, assign) BOOL openLogPending;
@end

@implementation GripesViewController

- (instancetype)initWithStore:(GripesStore *)store {
    if ((self = [super init])) {
        _store = store;
        _voice = [[GripesVoiceListener alloc] init];
        __weak typeof(self) weakSelf = self;
        _voice.onText = ^(NSString *text, BOOL isFinal) {
            [weakSelf callPage:@"gripesVoice" argument:@{@"type": isFinal ? @"final" : @"partial", @"text": text}];
        };
        _voice.onError = ^(NSString *message) {
            [weakSelf callPage:@"gripesVoice" argument:@{@"type": @"error", @"message": message}];
        };
    }
    return self;
}

+ (NSString *)bootScriptForMode:(NSString *)mode {
    NSDictionary *boot = @{
        @"palette": NSNull.null, @"mode": mode, @"themeId": NSNull.null, @"platform": @"ios",
        @"apiBase": [NSString stringWithFormat:@"http://%@:8326", GL_BAKED_HOST],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:boot options:0 error:NULL];
    return [NSString stringWithFormat:@"window.GL_BOOT = %@;", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
}

// Removes the ^ v check bar WKWebView shows above the keyboard for form fields. Only this app's
// web view: its WKContentView instance is re-classed to a runtime subclass whose inputAccessoryView is nil.
- (void)hideInputAccessoryBar {
    UIView *content = nil;
    for (UIView *v in self.webView.scrollView.subviews) {
        if ([NSStringFromClass(v.class) hasPrefix:@"WKContent"]) { content = v; break; }
    }
    NSAssert(content, @"WKContentView not found; cannot hide the input accessory bar");
    Class base = content.class;
    NSString *name = [NSStringFromClass(base) stringByAppendingString:@"_GripesNoAccessory"];
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
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:[GripesViewController bootScriptForMode:mode]
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
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

    NSURL *page = [NSBundle.mainBundle URLForResource:@"gripes" withExtension:@"html"];
    NSAssert(page, @"gripes.html missing from the app bundle");
    [self.webView loadFileURL:page allowingReadAccessToURL:NSBundle.mainBundle.resourceURL];
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
        result = @{@"token": GL_BAKED_TOKEN};
    } else if ([method isEqualToString:@"loadEntries"]) {
        result = @{@"entries": [self.store allEntries]};
    } else if ([method isEqualToString:@"upsertEntry"]) {
        if ([self.store upsertEntry:params[@"entry"] error:&nsError]) { result = @{}; if (self.requestSync) self.requestSync(8); }
        else error = [NSString stringWithFormat:@"upsertEntry failed: %@", nsError];
    } else if ([method isEqualToString:@"startVoice"]) {
        [self.voice startPreferringOnDevice:[params[@"onDevice"] boolValue]];
        result = @{};
    } else if ([method isEqualToString:@"stopVoice"]) {
        [self.voice stop];
        result = @{};
    } else {
        error = [NSString stringWithFormat:@"unsupported bridge method %@", method];
    }
    if (error) NSLog(@"[Gripes] %@", error);
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[ident ?: NSNull.null, result ?: NSNull.null, error ?: NSNull.null] options:0 error:NULL];
    NSString *args = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.__glReply.apply(null, %@)", args] completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[Gripes] __glReply failed: %@", e);
    }];
}

// ---- native -> page ----
- (void)callPage:(NSString *)name argument:(NSDictionary *)arg {
    NSString *literal = @"";
    if (arg) literal = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:arg options:0 error:NULL] encoding:NSUTF8StringEncoding];
    NSString *js = [NSString stringWithFormat:@"window.%@(%@)", name, literal];
    [self.webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[Gripes] calling %@ failed: %@", name, e);
    }];
}

- (void)openLog {
    if (self.pageLoaded) [self callPage:@"gripesOpenLog" argument:nil];
    else self.openLogPending = YES; // cold launch via gripes://log: the page opens on the log view anyway
}

- (void)entriesChanged {
    if (self.pageLoaded) [self callPage:@"gripesEntriesChanged" argument:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageLoaded = YES;
    self.openLogPending = NO;
#if DEBUG
    // Screenshot flow (gripes-shots.yml): GRIPES_SHOT=<scenario> swaps in demo data and a fixed view.
    // Delayed so the page's own startup load/re-rate pass has finished and cannot overwrite it.
    NSString *shot = NSProcessInfo.processInfo.environment[@"GRIPES_SHOT"];
    if (shot.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *js = [NSString stringWithFormat:@"window.__gripesShot('%@');"
                        "var d=document.createElement('div');d.style.cssText='position:fixed;right:4px;bottom:4px;font:10px monospace;color:#888;z-index:9';"
                        "d.textContent=innerWidth+'x'+innerHeight+' screen '+screen.width+'x'+screen.height;document.body.appendChild(d);", shot];
            [self.webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
                if (e) NSLog(@"[Gripes] shot %@ failed: %@", shot, e);
            }];
        });
    }
#endif
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[Gripes] page navigation failed: %@", error);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[Gripes] page load failed: %@", error);
}

@end
