#import "ListenViewController.h"

#import <WebKit/WebKit.h>

#import "BakedConfig.h"
#import "GLLog.h"
#import "ListenPlayer.h"
#import "ListenPocketView.h"
#import "ListenProbe.h"
#import "ListenRewind.h"
#import "ListenVoiceListener.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
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

@interface ListenViewController () <WKScriptMessageHandler>
@end

@implementation ListenViewController {
    ListenPlayer *_player;
    ListenPocketView *_pocket;
    ListenVoiceListener *_voice;
}

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kListenPort];
    return [self initWithURL:[NSURL URLWithString:urlString] displayName:@"listen"];
}

#pragma mark - Lifecycle

// GLWebModuleViewController keeps its WKWebView in a private property and
// exposes no accessor. Reading it through KVC leaves the shared base class
// (and Modules/WebBridge) untouched; ListenProbe logs that this works.
- (WKWebView *)listenWebView {
    return [self valueForKey:@"webView"];
}

- (void)viewDidLoad {
    [super viewDidLoad];

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
    WKWebView *webView = [self listenWebView];
    [webView.configuration.userContentController addScriptMessageHandler:handler name:@"listen"];
    GLLog(@"listen handler registered (webView=%@, controller=%@)", NSStringFromClass([webView class]),
          NSStringFromClass([webView.configuration.userContentController class]));

    [ListenProbe runIfRequestedWithWebView:webView];
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
        return [_player rewindSteps:steps slow:slow.integerValue];
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
    if (!window) return @"pocketMode: the Listen tab is not on screen";
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
