#import "GLWebBridge.h"

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

#import "BakedConfig.h"
#import "GLDefaultsKeys.h"
#import "GLManager.h"
#import "GLModuleRegistry.h"
#import "GLTheme.h"
#import "RecentRecordingsViewController.h"

typedef void (^GLWebBridgeReplyBlock)(NSDictionary *_Nullable result, NSString *_Nullable error);

// Same theme-server host/port every other file in this app builds directly
// from GL_BAKED_HOST (GLTheme.m, SettingsViewController.m, GLAppStateReporter.m,
// EventsViewController.m) -- duplicated rather than shared, matching that
// existing convention, since GLEndpointURL() raises when GL_BAKED_HOST is
// unbaked (true for every sim-test CI build) and every one of those files
// needs to fail through NSURLSession's ordinary error path instead.
static NSInteger const kGLWebBridgeThemeServerPort = 8304;

static NSURL *_Nullable GLWebBridgeThemeServerURL(NSString *path) {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld%@", GL_BAKED_HOST, (long)kGLWebBridgeThemeServerPort, path];
    return [NSURL URLWithString:urlString];
}

// Shared success/parse gate, matching SettingsViewController.m's
// JSONFromResponse:expectedClass: / GLTheme.m's GLThemeJSONFromResponse.
static id _Nullable GLWebBridgeJSONFromResponse(NSURLResponse *response, NSData *data, NSError *error, Class expectedClass) {
    if (error || data.length == 0) return nil;
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status < 200 || status > 299) return nil;
    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![parsed isKindOfClass:expectedClass]) return nil;
    return parsed;
}

@interface GLWebBridge ()
@property(nonatomic, weak) UIViewController *hostViewController;
@end

@implementation GLWebBridge

- (instancetype)initWithHostViewController:(UIViewController *)hostViewController {
    self = [super init];
    if (self) {
        _hostViewController = hostViewController;
    }
    return self;
}

#pragma mark - WKScriptMessageHandler

// Every method below calls `reply` on exactly one path: the ones with no
// network/async step (listModules, openModule, goBack, getMode, setMode,
// locationPermission, requestLocationPermission, configureWifiZone,
// getApiToken, getPref, setPref, unknown-method) call it synchronously,
// inline, on this same (main-thread) call; getThemeState and setTheme hand
// `reply` into a network completion handler that dispatches back to the main
// queue before calling it exactly once. -sendReplyToWebView:... itself
// dispatches to the main queue too, so evaluateJavaScript is always called
// on it regardless of which of those two paths a given call took.
- (void)userContentController:(WKUserContentController *)userContentController
       didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    NSString *requestId = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    NSString *methodName = [body[@"method"] isKindOfClass:[NSString class]] ? body[@"method"] : nil;
    NSDictionary *params = [body[@"params"] isKindOfClass:[NSDictionary class]] ? body[@"params"] : @{};
    WKWebView *webView = message.webView;

    if (requestId.length == 0 || methodName.length == 0 || webView == nil) {
        // No id (or no webView to reply on) means there is no channel to
        // signal an error back on -- nothing to do but drop the message.
        return;
    }

    GLWebBridgeReplyBlock reply = ^(NSDictionary *_Nullable result, NSString *_Nullable error) {
        [self sendReplyToWebView:webView requestId:requestId result:result error:error];
    };

    if ([methodName isEqualToString:@"listModules"]) {
        reply(@{@"modules": [GLModuleRegistry overflowModuleDescriptors]}, nil);

    } else if ([methodName isEqualToString:@"openModule"]) {
        NSString *identifier = [params[@"identifier"] isKindOfClass:[NSString class]] ? params[@"identifier"] : nil;
        BOOL opened = identifier != nil && [GLModuleRegistry openOverflowModuleWithIdentifier:identifier];
        // End-to-end proof this call actually reached native code, for
        // sim-test.yml's web-tap targets (UITEST_MORE_TILE_TAP): a hook that
        // never fires this bridge message (e.g. the page never rendered a
        // tappable tile) is a different failure than one that fires it and
        // gets NO back (the module lookup/open itself failed) -- both look
        // identical from a screenshot alone.
        NSLog(@"GLWebBridge: openModule identifier=%@ opened=%@", identifier, opened ? @"YES" : @"NO");
        reply(@{@"opened": @(opened)}, nil);

    } else if ([methodName isEqualToString:@"goBack"]) {
        [self.hostViewController.navigationController popViewControllerAnimated:YES];
        reply(@{}, nil);

    } else if ([methodName isEqualToString:@"getMode"]) {
        reply(@{@"mode": @((NSInteger)[GLTheme currentMode])}, nil);

    } else if ([methodName isEqualToString:@"setMode"]) {
        NSInteger raw = [params[@"mode"] integerValue];
        [GLTheme setCurrentMode:(GLThemeMode)raw];
        reply(@{}, nil);

    } else if ([methodName isEqualToString:@"getThemeState"]) {
        [self fetchThemeStateWithReply:reply];

    } else if ([methodName isEqualToString:@"setTheme"]) {
        NSString *themeId = [params[@"id"] isKindOfClass:[NSString class]] ? params[@"id"] : nil;
        [self setThemeId:themeId reply:reply];

    } else if ([methodName isEqualToString:@"locationPermission"]) {
        reply(@{@"status": [self locationPermissionStatusString]}, nil);

    } else if ([methodName isEqualToString:@"requestLocationPermission"]) {
        [self requestLocationPermission];
        reply(@{}, nil);

    } else if ([methodName isEqualToString:@"configureWifiZone"]) {
        [self presentWifiZoneConfiguration];
        reply(@{}, nil);

    } else if ([methodName isEqualToString:@"getApiToken"]) {
        [self replyWithApiTokenForFrameURL:message.frameInfo.request.URL reply:reply];

    } else if ([methodName isEqualToString:@"getPref"]) {
        [self getPrefWithParams:params reply:reply];

    } else if ([methodName isEqualToString:@"setPref"]) {
        [self setPrefWithParams:params reply:reply];

    } else {
        reply(nil, [NSString stringWithFormat:@"unknown method %@", methodName]);
    }
}

#pragma mark - Reply plumbing

// NSJSONSerialization end to end -- the reply is built as a plain
// array/dictionary/string/number/NSNull tree and handed to
// dataWithJSONObject:, never string-formatted from page/user content
// directly into the evaluated script. The only literal text in the script
// itself is the fixed wrapper around the JSON blob.
- (void)sendReplyToWebView:(WKWebView *)webView
                  requestId:(NSString *)requestId
                     result:(nullable NSDictionary *)result
                      error:(nullable NSString *)error {
    NSArray *args = @[requestId, result ?: [NSNull null], error ?: [NSNull null]];
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:args options:0 error:&jsonError];
    if (jsonError || data == nil) {
        NSLog(@"GLWebBridge: failed to serialize reply for request %@: %@", requestId, jsonError.localizedDescription);
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"(function(a){window.__glReply(a[0], a[1], a[2]);})(%@);", json];
    dispatch_async(dispatch_get_main_queue(), ^{
        [webView evaluateJavaScript:script completionHandler:nil];
    });
}

#pragma mark - Theme

- (void)fetchThemeStateWithReply:(GLWebBridgeReplyBlock)reply {
    NSURL *themesURL = GLWebBridgeThemeServerURL(@"/themes.json");
    if (!themesURL) {
        reply(@{@"selectedId": [NSNull null], @"themes": [NSNull null], @"error": @"invalid theme server URL"}, nil);
        return;
    }

    NSURLSessionDataTask *themesTask = [[NSURLSession sharedSession]
        dataTaskWithURL:themesURL
      completionHandler:^(NSData *themesData, NSURLResponse *themesResponse, NSError *themesError) {
        NSArray *themes = GLWebBridgeJSONFromResponse(themesResponse, themesData, themesError, [NSArray class]);
        if (!themes) {
            dispatch_async(dispatch_get_main_queue(), ^{
                reply(@{@"selectedId": [NSNull null], @"themes": [NSNull null],
                        @"error": @"couldn't reach the theme server"}, nil);
            });
            return;
        }

        NSURL *currentURL = GLWebBridgeThemeServerURL(@"/api/theme");
        NSURLSessionDataTask *currentTask = [[NSURLSession sharedSession]
            dataTaskWithURL:currentURL
          completionHandler:^(NSData *currentData, NSURLResponse *currentResponse, NSError *currentError) {
            NSDictionary *parsed = GLWebBridgeJSONFromResponse(currentResponse, currentData, currentError, [NSDictionary class]);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!parsed) {
                    reply(@{@"selectedId": [NSNull null], @"themes": [NSNull null],
                            @"error": @"couldn't reach the theme server"}, nil);
                    return;
                }
                id themeValue = parsed[@"theme"];
                NSString *selectedId = [themeValue isKindOfClass:[NSString class]] ? themeValue : nil;
                reply(@{@"selectedId": selectedId ?: [NSNull null], @"themes": themes, @"error": [NSNull null]}, nil);
            });
        }];
        [currentTask resume];
    }];
    [themesTask resume];
}

- (void)setThemeId:(nullable NSString *)themeId reply:(GLWebBridgeReplyBlock)reply {
    NSURL *url = GLWebBridgeThemeServerURL(@"/api/theme");
    if (!url) {
        reply(@{@"ok": @NO, @"error": @"invalid theme server URL"}, nil);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"PUT";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"theme": themeId ?: [NSNull null]}
                                                        options:0
                                                          error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (error || status < 200 || status > 299) {
                reply(@{@"ok": @NO, @"error": error.localizedDescription ?: @"PUT /api/theme failed"}, nil);
                return;
            }
            // Re-themes the native chrome immediately, same as
            // SettingsViewController.m's own successful-PUT path -- without
            // this, picking a theme here would only re-theme THIS page (the
            // one place that already re-fetches /api/theme itself) and leave
            // the tab bar/nav bars showing the previous palette until the
            // app is force-quit and relaunched.
            [GLTheme refreshPaletteFromServer];
            reply(@{@"ok": @YES, @"error": [NSNull null]}, nil);
        });
    }];
    [task resume];
}

#pragma mark - Location

- (NSString *)locationPermissionStatusString {
    switch ([GLManager sharedManager].locationManager.authorizationStatus) {
        case kCLAuthorizationStatusAuthorizedAlways: return @"always";
        case kCLAuthorizationStatusAuthorizedWhenInUse: return @"whenInUse";
        case kCLAuthorizationStatusDenied: return @"denied";
        case kCLAuthorizationStatusRestricted: return @"restricted";
        case kCLAuthorizationStatusNotDetermined: return @"notDetermined";
    }
    return @"notDetermined";
}

- (void)requestLocationPermission {
    CLAuthorizationStatus status = [GLManager sharedManager].locationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusNotDetermined) {
        [[GLManager sharedManager] requestAuthorizationPermission];
        return;
    }
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        // iOS will not re-prompt once denied/restricted -- Settings is the
        // only way back, same as SettingsViewController's own handling.
        NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if (settingsURL) {
            [[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
        }
    }
}

#pragma mark - Wifi zone

- (void)presentWifiZoneConfiguration {
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Location" bundle:nil];
    UIViewController *wifiZoneViewController =
        [storyboard instantiateViewControllerWithIdentifier:@"WifiZoneViewController"];
    [self.hostViewController presentViewController:wifiZoneViewController animated:YES completion:nil];
}

#pragma mark - API token

- (void)replyWithApiTokenForFrameURL:(nullable NSURL *)frameURL reply:(GLWebBridgeReplyBlock)reply {
    BOOL isFileURL = frameURL.isFileURL;
    BOOL isBakedHost = frameURL.host != nil && [frameURL.host isEqualToString:GL_BAKED_HOST];
    if (isFileURL || isBakedHost) {
        reply(@{@"token": GL_BAKED_TOKEN}, nil);
    } else {
        reply(nil, @"getApiToken denied: requesting page is neither file:// nor GL_BAKED_HOST");
    }
}

#pragma mark - Prefs

- (nullable NSString *)defaultsKeyForPrefKey:(NSString *)key {
    if ([key isEqualToString:@"moreOrder"]) return GLMoreGridOrderDefaultsName;
    if ([key isEqualToString:@"moreHeroes"]) return GLMoreGridHeroesDefaultsName;
    if ([key isEqualToString:@"cleanTranscripts"]) return GLJournalCleanedTranscriptsDefaultsName;
    return nil;
}

- (void)getPrefWithParams:(NSDictionary *)params reply:(GLWebBridgeReplyBlock)reply {
    NSString *key = [params[@"key"] isKindOfClass:[NSString class]] ? params[@"key"] : nil;
    NSString *defaultsKey = key ? [self defaultsKeyForPrefKey:key] : nil;
    if (!defaultsKey) {
        reply(nil, [NSString stringWithFormat:@"unknown pref key %@", key ?: @"(missing)"]);
        return;
    }
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:defaultsKey];
    reply(@{@"value": value ?: [NSNull null]}, nil);
}

- (void)setPrefWithParams:(NSDictionary *)params reply:(GLWebBridgeReplyBlock)reply {
    NSString *key = [params[@"key"] isKindOfClass:[NSString class]] ? params[@"key"] : nil;
    NSString *defaultsKey = key ? [self defaultsKeyForPrefKey:key] : nil;
    if (!defaultsKey) {
        reply(nil, [NSString stringWithFormat:@"unknown pref key %@", key ?: @"(missing)"]);
        return;
    }
    id value = params[@"value"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (value == nil || [value isKindOfClass:[NSNull class]]) {
        [defaults removeObjectForKey:defaultsKey];
    } else {
        [defaults setObject:value forKey:defaultsKey];
    }
    reply(@{}, nil);
}

@end
