#import "ListenViewController.h"

#import <WebKit/WebKit.h>

#import "ListenBakedConfig.h"
#import "GLLog.h"
#import "GLOfflineShell.h"
#import "ListenPlayer.h"
#import "ListenPocketView.h"
#import "ListenProbe.h"
#import "ListenRewind.h"
#import "ListenVoiceListener.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// ListenApp/ListenBakedConfig.h); this app only owns its own port.
static NSInteger const kListenPort = 8315;

// WKUserContentController retains its handlers strongly; the view controller
// owns the web view, so hand the controller a weak forwarder instead of self.
@interface ListenScriptHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation ListenScriptHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

@interface ListenViewController () <WKScriptMessageHandler, WKNavigationDelegate, GLOfflineShellLoaderDelegate>
@end

@implementation ListenViewController {
    WKWebView *_webView;
    UILabel *_errorLabel;
    UIButton *_retryButton;
    // Falls back to the saved shell.html when a cold launch cannot reach the server.
    GLOfflineShellLoader *_shellLoader;
    ListenPlayer *_player;
    ListenPocketView *_pocket;
    ListenVoiceListener *_voice;
}

- (WKWebView *)listenWebView { return _webView; }

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    _webView.navigationDelegate = self;
    _webView.translatesAutoresizingMaskIntoConstraints = NO;
    _webView.opaque = NO;
    _webView.backgroundColor = [UIColor clearColor];
    _webView.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_webView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_webView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_webView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_webView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    ]];

    _errorLabel = [[UILabel alloc] init];
    _errorLabel.numberOfLines = 0;
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.textColor = [UIColor secondaryLabelColor];
    _errorLabel.hidden = YES;
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_errorLabel];
    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    [_retryButton addTarget:self action:@selector(loadPage) forControlEvents:UIControlEventTouchUpInside];
    _retryButton.hidden = YES;
    _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_retryButton];
    [NSLayoutConstraint activateConstraints:@[
        [_errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [_errorLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [_errorLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [_retryButton.topAnchor constraintEqualToAnchor:_errorLabel.bottomAnchor constant:12],
        [_retryButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];

    _shellLoader = [[GLOfflineShellLoader alloc] initWithWebView:_webView
                                                        hostView:self.view
                                                           cache:[GLOfflineShellCache sharedCache]
                                                         session:[NSURLSession sharedSession]];
    _shellLoader.delegate = self;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];

    _player = [[ListenPlayer alloc] init];
    _voice = [[ListenVoiceListener alloc] initWithPlayer:_player];
    __weak typeof(self) weakSelf = self;
    _player.stateChanged = ^{ [weakSelf emitState]; };
    _player.errorReported = ^(NSString *message) { [weakSelf emitEvent:@"error" payload:@{@"message": message}]; };
    _player.nextTrackOverride = ^BOOL{
        ListenViewController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_pocket) return NO;
        if (![strongSelf->_player.settings[@"pocketDoublePress"] isEqual:@"voice"]) return NO;
        [strongSelf->_voice startWindow];
        return YES;
    };
    _voice.onListeningChanged = ^{ [weakSelf emitState]; };
    _voice.onHeard = ^(NSString *transcript, NSString *matched) {
        [weakSelf emitEvent:@"heard" payload:@{@"transcript": transcript, @"matched": matched ?: [NSNull null]}];
    };
    _voice.onCommand = ^(NSString *name, NSInteger idx) { [weakSelf emitCommand:name idx:idx]; };
    _voice.onError = ^(NSString *message) { [weakSelf emitEvent:@"error" payload:@{@"message": message}]; };

    ListenScriptHandler *handler = [[ListenScriptHandler alloc] init];
    handler.target = self;
    WKWebView *webView = _webView;
    [webView.configuration.userContentController addScriptMessageHandler:handler name:@"listen"];
    GLLog(@"listen handler registered (webView=%@, controller=%@)", NSStringFromClass([webView class]),
          NSStringFromClass([webView.configuration.userContentController class]));

    [self loadPage];
    [ListenProbe runIfRequestedWithWebView:webView];
}

#pragma mark - Page loading

- (void)loadPage {
    _errorLabel.hidden = YES;
    _retryButton.hidden = YES;
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kListenPort];
    [_shellLoader loadLiveRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]];
}

- (void)appWillEnterForeground {
    [_shellLoader swapToLiveIfReachable];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)offlineShellLoaderDidShowShell:(GLOfflineShellLoader *)loader {
    _errorLabel.hidden = YES;
    _retryButton.hidden = YES;
}

- (void)offlineShellLoader:(GLOfflineShellLoader *)loader didFailLiveLoad:(NSError *)error {
    [self showLoadError:error];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    [_shellLoader webView:webView didCommitNavigation:navigation];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [_shellLoader webView:webView didFinishNavigation:navigation];
}

- (void)showLoadError:(NSError *)error {
    GLLog(@"page load failed: %@", error);
    _errorLabel.text = [NSString stringWithFormat:@"Couldn't reach Listen at %@:%ld\n%@",
                        GL_BAKED_HOST, (long)kListenPort, error.localizedDescription];
    _errorLabel.hidden = NO;
    _retryButton.hidden = NO;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if ([_shellLoader webView:webView didFailProvisionalNavigation:navigation withError:error]) return;
    [self showLoadError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [_shellLoader webView:webView didFailNavigation:navigation];
    [self showLoadError:error];
}

#pragma mark - Page -> native

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]] || !body[@"id"] || ![body[@"method"] isKindOfClass:[NSString class]]) {
        [self emitEvent:@"error" payload:@{@"message": [NSString stringWithFormat:
            @"listen message must be {id, method, params}, got %@", body]}];
        return;
    }
    id messageId = body[@"id"];
    NSString *method = body[@"method"];
    id rawParams = body[@"params"];
    NSDictionary *params = [rawParams isKindOfClass:[NSDictionary class]] ? rawParams : @{};
    GLLog(@"listen call %@ (id=%@)", method, messageId);

    id result = @{};
    NSString *error = [self perform:method params:params result:&result];
    [self replyTo:messageId result:error ? nil : result error:error];
}

/// Runs one protocol method. Returns an error string or nil; `result` defaults to {}.
- (NSString *)perform:(NSString *)method params:(NSDictionary *)params result:(id *)result {
    if ([method isEqual:@"load"]) {
        NSString *itemId = params[@"itemId"], *title = params[@"title"];
        NSArray *sections = params[@"sections"];
        NSDictionary *settings = params[@"settings"];
        NSNumber *startIdx = params[@"startIdx"];
        if (![itemId isKindOfClass:[NSString class]]) return @"load: itemId must be a string";
        if (![title isKindOfClass:[NSString class]]) return @"load: title must be a string";
        if (![sections isKindOfClass:[NSArray class]]) return @"load: sections must be an array";
        if (![settings isKindOfClass:[NSDictionary class]]) return @"load: settings must be an object";
        if (![startIdx isKindOfClass:[NSNumber class]]) return @"load: startIdx must be a number";
        return [_player loadItemId:itemId title:title sections:sections settings:settings startIdx:startIdx.integerValue];
    }
    if ([method isEqual:@"play"]) return [_player play];
    if ([method isEqual:@"pause"]) return [_player pause];
    if ([method isEqual:@"toggle"]) return [_player toggle];
    if ([method isEqual:@"next"]) return [_player next];
    if ([method isEqual:@"prev"]) return [_player prev];
    if ([method isEqual:@"goto"]) {
        NSNumber *idx = params[@"idx"];
        if (![idx isKindOfClass:[NSNumber class]]) return @"goto: idx must be a number";
        return [_player gotoIdx:idx.integerValue];
    }
    if ([method isEqual:@"replay"]) {
        NSString *kind = params[@"kind"];
        if (![kind isKindOfClass:[NSString class]]) return @"replay: kind must be a string";
        return [_player replay:kind];
    }
    if ([method isEqual:@"rewind"]) {
        NSArray *steps = params[@"steps"];
        NSNumber *slow = params[@"slow"];
        NSString *error = [ListenRewind validateSteps:steps slow:slow];
        if (error) return [@"rewind: " stringByAppendingString:error];
        id after = params[@"after"];
        if (after == nil) after = @"resume";
        if (![after isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"rewind: unknown rewind after %@", after];
        return [_player rewindSteps:steps slow:slow.integerValue after:after];
    }
    if ([method isEqual:@"loop"]) {
        NSNumber *on = params[@"on"];
        if (![on isKindOfClass:[NSNumber class]]) return @"loop: on must be a bool";
        return [_player setLoop:on.boolValue];
    }
    if ([method isEqual:@"setSettings"]) {
        NSDictionary *settings = params[@"settings"];
        if (![settings isKindOfClass:[NSDictionary class]]) return @"setSettings: settings must be an object";
        return [_player setSettings:settings];
    }
    if ([method isEqual:@"getState"]) {
        *result = [self fullState];
        return nil;
    }
    if ([method isEqual:@"pocketMode"]) {
        NSNumber *on = params[@"on"];
        if (![on isKindOfClass:[NSNumber class]]) return @"pocketMode: on must be a bool";
        return [self setPocketMode:on.boolValue];
    }
    if ([method isEqual:@"voice"]) {
        NSNumber *on = params[@"on"];
        if (![on isKindOfClass:[NSNumber class]]) return @"voice: on must be a bool";
        if (on.boolValue) [_voice startWindow]; else [_voice cancel];
        return nil;
    }
    return [NSString stringWithFormat:@"unknown listen method %@", method];
}

#pragma mark - Pocket mode

- (NSString *)setPocketMode:(BOOL)on {
    if (on == (_pocket != nil)) return nil;
    if (!on) {
        [_pocket dismiss];
        _pocket = nil;
        [self emitState];
        return nil;
    }
    UIWindow *window = self.view.window;
    if (!window) return @"pocketMode: Listen is not on screen";
    ListenPocketView *pocket = [[ListenPocketView alloc] initWithPlayer:_player];
    __weak typeof(self) weakSelf = self;
    pocket.onSave = ^{
        ListenViewController *strongSelf = weakSelf;
        if (strongSelf) [strongSelf emitCommand:@"save" idx:strongSelf->_player.currentIdx];
    };
    pocket.onExitRequested = ^{ [weakSelf setPocketMode:NO]; };
    pocket.onError = ^(NSString *message) { [weakSelf emitEvent:@"error" payload:@{@"message": message}]; };
    NSString *error = [pocket presentInWindow:window];
    if (error) return error;
    _pocket = pocket;
    [self emitState];
    return nil;
}

#pragma mark - Native -> page

- (NSDictionary *)fullState {
    NSMutableDictionary *state = [[_player stateDictionary] mutableCopy];
    state[@"pocket"] = @(_pocket != nil);
    state[@"listening"] = @(_voice.listening);
    return state;
}

- (void)emitState {
    NSDictionary *state = [self fullState];
    if (_pocket) {
        [_pocket refreshRewindLabel];
        NSString *step = [state[@"step"] isKindOfClass:[NSString class]] ? [state[@"step"] capitalizedString] : @"Done";
        [_pocket setStatusText:[NSString stringWithFormat:@"%@ · %ld/%ld", step,
                                (long)_player.currentIdx + 1, (long)_player.sectionCount]];
    }
    [self emitEvent:@"state" payload:state];
}

- (void)emitCommand:(NSString *)name idx:(NSInteger)idx {
    [self emitEvent:@"command" payload:@{@"name": name, @"idx": @(idx)}];
}

- (void)emitEvent:(NSString *)name payload:(NSDictionary *)payload {
    [self callPage:@"__listenEvent" arguments:@[name, payload]];
}

- (void)replyTo:(id)messageId result:(id)result error:(NSString *)error {
    [self callPage:@"__listenReply" arguments:@[messageId, result ?: [NSNull null], error ?: [NSNull null]]];
}

- (void)callPage:(NSString *)function arguments:(NSArray *)arguments {
    if (![NSJSONSerialization isValidJSONObject:arguments]) {
        GLLog(@"cannot serialize %@ arguments: %@", function, arguments);
        return;
    }
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:&jsonError];
    if (!data) {
        GLLog(@"JSON for %@ failed: %@", function, jsonError);
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"if (typeof window.%@ === 'function') window.%@.apply(null, %@);",
                        function, function, json];
    [[self listenWebView] evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        if (error) GLLog(@"evaluateJavaScript for %@ failed: %@", function, error);
    }];
}

@end
