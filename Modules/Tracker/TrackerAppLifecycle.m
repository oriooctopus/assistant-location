#import "TrackerAppLifecycle.h"

#import <CoreLocation/CoreLocation.h>

#import "GLManager.h"
#import "BakedConfig.h"
#import "GLEndpoints.h"
#import "GLDefaultsKeys.h"

@implementation TrackerAppLifecycle

#pragma mark - Background-delivery lifecycle observers

// SceneDelegate used to call GLManager directly at sceneWillEnterForeground /
// sceneDidEnterBackground / sceneWillResignActive, and AppDelegate called
// GLManager directly from applicationWillTerminate. Background location
// delivery is the app's core function, so these calls are preserved exactly
// — same GLManager methods, same lifecycle points — just triggered by this
// class observing the equivalent system notifications itself instead of the
// shell naming GLManager.
//
// +load runs exactly once per class, the first time the Objective-C runtime
// loads it into the process (there is never an instance of this class), so
// this registers each observer exactly once for the app's lifetime — never
// per scene connect, never duplicated.
+ (void)load {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // Was SceneDelegate's sceneDidEnterBackground:.
    [nc addObserverForName:UISceneDidEnterBackgroundNotification
                     object:nil
                      queue:nil
                 usingBlock:^(NSNotification *note) {
        // Restores the ordering guarantee main.m relied on: NSUserDefaults
        // synchronize ran before GLManager's applicationDidEnterBackground.
        // The shell's own applicationDidEnterBackground: also synchronizes,
        // but its relative order vs. this observer is undefined, so this
        // class no longer depends on the shell for it.
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[GLManager sharedManager] applicationDidEnterBackground];
    }];

    // Was SceneDelegate's sceneWillResignActive:.
    [nc addObserverForName:UISceneWillDeactivateNotification
                     object:nil
                      queue:nil
                 usingBlock:^(NSNotification *note) {
        [[GLManager sharedManager] applicationWillResignActive];
    }];

    // Was AppDelegate's applicationWillTerminate:. UIKit posts this
    // notification around the same point it calls the app delegate's
    // applicationWillTerminate:.
    [nc addObserverForName:UIApplicationWillTerminateNotification
                     object:nil
                      queue:nil
                 usingBlock:^(NSNotification *note) {
        // Same ordering restoration as the background observer above.
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[GLManager sharedManager] applicationWillTerminate];
    }];
}

#pragma mark - Launch

+ (void)didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Was SceneDelegate's sceneWillEnterForeground:. Moved here because
    // UISceneWillEnterForegroundNotification is only guaranteed to fire on a
    // background->foreground round trip, not on a cold launch — but
    // GLPurgeQueueOnNextLaunchDefaultsName's own semantics ("on next
    // launch", set via the Settings.bundle toggle) mean this check must run
    // on every launch, cold or warm. didFinishLaunchingWithOptions: is
    // UIKit-guaranteed to run at launch, so it runs here instead, exactly
    // once — never in the foreground observer, so it cannot run twice.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:GLPurgeQueueOnNextLaunchDefaultsName]) {
        [[GLManager sharedManager] deleteAllData];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLPurgeQueueOnNextLaunchDefaultsName];
    }

    // UIApplicationLaunchOptionsLocationKey means iOS relaunched the app in
    // the background specifically to deliver a location update. Only this
    // module knows or cares what that key means — the shell just passes
    // launchOptions through unmodified.
    if ([launchOptions objectForKey:UIApplicationLaunchOptionsLocationKey]) {
        [[GLManager sharedManager] logAction:@"application_launched_with_location"];
    }

    // Assistant fork: ship pre-pointed at our own location-ingest server
    // (~/coding/assistant/location-server, port 8302). On a release build
    // GLManager's applyBakedConfiguration forces both endpoint and token from
    // BakedConfig.h; this covers the placeholder-token (dev/simulator) build,
    // where that method deliberately does nothing.
    if ([[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName] == nil) {
        [[NSUserDefaults standardUserDefaults] setObject:GLEndpointURL(@"/overland").absoluteString
                                                    forKey:GLAPIEndpointDefaultsName];
    }

    // UI-test hook: let an XCUITest override the endpoint and force tracking on
    // via launch environment, so it only has to handle the permission dialog.
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if (env[@"UITEST_ENDPOINT"]) {
        [[NSUserDefaults standardUserDefaults] setObject:env[@"UITEST_ENDPOINT"]
                                                    forKey:GLAPIEndpointDefaultsName];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLTrackingStateDefaultsName];
        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:GLPointsPerBatchDefaultsName];
        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:GLSendIntervalDefaultsName];
    }

    // Assistant fork: this is a personal always-on location logger, so on the
    // very first launch auto-enable tracking (instead of waiting for the user
    // to find the in-app toggle). Setting the tracking-state default before
    // GLManager is created makes restoreTrackingState start location updates,
    // which triggers the iOS permission prompt right away. Guarded by a
    // one-time flag so the user can still turn tracking off later and have it
    // stay off.
    if (![[NSUserDefaults standardUserDefaults] boolForKey:GLAutoEnableTrackingDefaultsName]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLTrackingStateDefaultsName];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLAutoEnableTrackingDefaultsName];
    }

    // The trip system used to install shortcut items (mode icons + "Stop
    // Trip") via +refreshTripModeShortcutItems. That's gone, and this module
    // owns no shortcut items at all now — but a phone upgraded from a build
    // that still has trip shortcuts on the home screen won't otherwise lose
    // them, since nothing else ever clears shortcutItems. Do it once, guarded
    // so a user who (somehow) adds shortcut items of their own later isn't
    // fought on every launch.
    NSString *kDidClearTripShortcuts = @"AssistantDidClearTripShortcuts";
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kDidClearTripShortcuts]) {
        UIApplication.sharedApplication.shortcutItems = @[];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDidClearTripShortcuts];
    }

    [GLManager sharedManager];

    // NOTE: the location-permission request is fired from TrackingViewController's
    // viewDidAppear, not here — a didFinishLaunching request is too early (the
    // app isn't foreground-active yet) and the dialog silently never presents.
}

#pragma mark - URL routing

// overland://setup?url=...&token=...&device_id=...&unique_id=...
+ (BOOL)handleURL:(NSURL *)url {
    if (![[url host] isEqualToString:@"setup"]) {
        return NO;
    }

    NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSArray *queryItems = urlComponents.queryItems;
    NSString *endpoint = [self queryValueForKey:@"url" fromQueryItems:queryItems];
    NSString *token    = [self queryValueForKey:@"token" fromQueryItems:queryItems];
    NSString *deviceId = [self queryValueForKey:@"device_id" fromQueryItems:queryItems];
    NSString *uniqueId = [self queryValueForKey:@"unique_id" fromQueryItems:queryItems];
    NSLog(@"Saving new config endpoint=%@ token=%@ device_id=%@ unique_id=%@", endpoint, token, deviceId, uniqueId);
    [[GLManager sharedManager] saveNewDeviceId:deviceId];
    [[GLManager sharedManager] saveNewAPIEndpoint:endpoint andAccessToken:token];
    [[NSUserDefaults standardUserDefaults] setBool:[uniqueId isEqualToString:@"yes"] forKey:GLIncludeUniqueIdDefaultsName];
    return YES;
}

+ (NSString *)queryValueForKey:(NSString *)key fromQueryItems:(NSArray *)queryItems {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name=%@", key];
    NSURLQueryItem *queryItem = [[queryItems filteredArrayUsingPredicate:predicate] firstObject];
    return queryItem.value;
}

#pragma mark - User-activity routing

+ (BOOL)handleUserActivity:(NSUserActivity *)activity {
    NSString *startTrackingActivityType =
        [NSString stringWithFormat:@"%@.startTracking", [[NSBundle mainBundle] bundleIdentifier]];

    if (![activity.activityType isEqualToString:startTrackingActivityType]) {
        return NO;
    }

    NSLog(@"startTracking - called from shortcut");
    [[GLManager sharedManager] startAllUpdates];
    return YES;
}

#pragma mark - Shortcut-item routing

+ (BOOL)handleShortcutItem:(UIApplicationShortcutItem *)item {
    // This module installs no shortcut items of its own (the trip-mode /
    // "Stop Trip" items it used to install are gone), so it owns no shortcut
    // type — always defer to the next module.
    return NO;
}

#pragma mark - Diagnostics

+ (NSString *)diagnosticSummary {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *endpoint = [defaults stringForKey:GLAPIEndpointDefaultsName];
    if (endpoint.length == 0) {
        endpoint = @"NOT SET";
    }
    NSString *token = [[GLManager sharedManager] apiAccessToken];
    NSString *auth;
    switch ([[[CLLocationManager alloc] init] authorizationStatus]) {
        case kCLAuthorizationStatusAuthorizedAlways:    auth = @"Always"; break;
        case kCLAuthorizationStatusAuthorizedWhenInUse: auth = @"When In Use"; break;
        case kCLAuthorizationStatusDenied:              auth = @"Denied"; break;
        case kCLAuthorizationStatusRestricted:          auth = @"Restricted"; break;
        default:                                        auth = @"Not Determined"; break;
    }

    return [NSString stringWithFormat:
            @"endpoint: %@\n"
            @"access token: %@\n"
            @"auth header: %@\n"
            @"location auth: %@",
            endpoint,
            token.length > 0 ? @"yes" : @"no",
            [[GLManager sharedManager] authorizationHeaderState],
            auth];
}

@end
