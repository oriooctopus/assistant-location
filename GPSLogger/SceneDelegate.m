//
//  SceneDelegate.m
//  Overland
//
//  Created by Aaron Parecki on 12/10/23.
//  Copyright © 2023 Aaron Parecki. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

#import "SceneDelegate.h"
#import "GLManager.h"
#import "GLUploadViewController.h"
#import "NSArray+map.h"
#import "BuildStamp.generated.h"

// Key holds the build stamp the diagnostic was last shown for, so the alert
// appears exactly once per installed build rather than once per install.
static NSString *const GLBuildAlertShownStampKey = @"AssistantBuildAlertShownStamp";

@implementation SceneDelegate

#pragma mark - First-launch build diagnostic

// Presented from the scene delegate, on the window's root view controller,
// deliberately: the previous build markers all lived inside a custom view and
// none of them were readable on the device. A UIAlertController owns its own
// window-level presentation, so it shows up whether or not the app's own views
// draw anything useful.
- (void)presentBuildDiagnosticIfNeeded:(UIScene *)scene {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *shown = [defaults stringForKey:GLBuildAlertShownStampKey];
    if ([shown isEqualToString:GL_BUILD_STAMP]) {
        return;
    }

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    UIWindow *window = windowScene.windows.firstObject;
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (presenter == nil) {
        return; // Try again on the next activation, once the scene has a root.
    }

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

    NSString *body = [NSString stringWithFormat:
                      @"build stamp: %@\n"
                      @"bundle version: %@\n"
                      @"app name: %@\n\n"
                      @"endpoint: %@\n"
                      @"access token: %@\n"
                      @"auth header: %@\n"
                      @"location auth: %@",
                      GL_BUILD_STAMP,
                      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],
                      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"],
                      endpoint,
                      token.length > 0 ? @"yes" : @"no",
                      [[GLManager sharedManager] authorizationHeaderState],
                      auth];

    NSLog(@"Build diagnostic: %@", [body stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Build Identity"
                                            message:body
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [defaults setObject:GL_BUILD_STAMP forKey:GLBuildAlertShownStampKey];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.

    // Test hook (same pattern as UITEST_ENDPOINT in AppDelegate): let the
    // simulator smoke test select a tab, so CI can screenshot the Settings tab
    // and not just the one the app opens on.
    NSString *tab = [[NSProcessInfo processInfo] environment][@"UITEST_TAB"];
    if(tab != nil) {
        UIViewController *root = self.window.rootViewController;
        if([root isKindOfClass:[UITabBarController class]]) {
            [(UITabBarController *)root setSelectedIndex:[tab integerValue]];
        }
    }

    // Slight delay so the root view controller has finished its own
    // presentation work before the diagnostic goes up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self presentBuildDiagnosticIfNeeded:scene];
    });
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
    
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLPurgeQueueOnNextLaunchDefaultsName]) {
        [[GLManager sharedManager] deleteAllData];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLPurgeQueueOnNextLaunchDefaultsName];
    }

}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
    
    NSLog(@"Application is entering the background");
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[GLManager sharedManager] applicationDidEnterBackground];
}


- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    UIOpenURLContext *context = [URLContexts anyObject];
    NSURL *url = context.URL;
    
    if([[url host] isEqualToString:@"setup"]) {
        NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSArray *queryItems  = urlComponents.queryItems;
        NSString *endpoint = [self queryValueForKey:@"url" fromQueryItems:queryItems];
        NSString *token    = [self queryValueForKey:@"token" fromQueryItems:queryItems];
        NSString *deviceId = [self queryValueForKey:@"device_id" fromQueryItems:queryItems];
        NSString *uniqueId = [self queryValueForKey:@"unique_id" fromQueryItems:queryItems];
        NSLog(@"Saving new config endpoint=%@ token=%@ device_id=%@ unique_id=%@", endpoint, token, deviceId, uniqueId);
        [[GLManager sharedManager] saveNewDeviceId:deviceId];
        [[GLManager sharedManager] saveNewAPIEndpoint:endpoint andAccessToken:token];
        [[NSUserDefaults standardUserDefaults] setBool:[uniqueId isEqualToString:@"yes"] forKey:GLIncludeUniqueIdDefaultsName];
    }
}

- (NSString *)queryValueForKey:(NSString *)key fromQueryItems:(NSArray *)queryItems
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name=%@", key];
    NSURLQueryItem *queryItem = [[queryItems filteredArrayUsingPredicate:predicate] firstObject];
    return queryItem.value;
}

#pragma mark - Upload tab

// The Upload tab is appended in code rather than added to Main.storyboard.
// The storyboard's tab bar carries every inherited screen the fork hides, and
// editing it by hand to add one controller risks disturbing the rest of the
// scene graph for no benefit — the view controller owns its own tab bar item,
// so appending it here is all it needs.
- (void)addUploadTab {
    UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
    if(![tabs isKindOfClass:[UITabBarController class]]) {
        NSLog(@"Upload tab: root view controller is %@, not a tab bar controller", tabs.class);
        return;
    }
    for(UIViewController *vc in tabs.viewControllers) {
        if([vc.restorationIdentifier isEqualToString:@"GLUploadTab"]) {
            return; // Scene reconnected; the tab is already there.
        }
    }
    NSMutableArray *controllers = [tabs.viewControllers mutableCopy];
    [controllers addObject:[[GLUploadViewController alloc] init]];
    tabs.viewControllers = controllers;
    NSLog(@"Upload tab added; tab bar now has %lu tabs", (unsigned long)controllers.count);
}

#pragma mark - Quick Actions

// https://developer.apple.com/documentation/uikit/menus_and_shortcuts/add_home_screen_quick_actions?language=objc

- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
    
    [[GLManager sharedManager] applicationWillResignActive];

    UIApplication *app = UIApplication.sharedApplication;

    // Register home screen actions
    if(![GLManager sharedManager].tripInProgress) {
        NSArray *tripModes = [[GLManager sharedManager] tripModesByFrequency];
        app.shortcutItems = [tripModes mapObjectsUsingBlock:^id(id obj, NSUInteger idx) {
            UIApplicationShortcutIcon *icon = [UIApplicationShortcutIcon iconWithTemplateImageName:obj];
            return [[UIApplicationShortcutItem alloc] initWithType:obj
                                                    localizedTitle:obj
                                                 localizedSubtitle:nil
                                                              icon:icon
                                                          userInfo:nil];
        }];
    } else {
        
        UIApplicationShortcutIcon *icon = [UIApplicationShortcutIcon iconWithSystemImageName:@"stop.circle.fill"];
        UIApplicationShortcutItem *item = [[UIApplicationShortcutItem alloc] initWithType:@"stop"
                                                                           localizedTitle:@"Stop Trip"
                                                                        localizedSubtitle:nil
                                                                                     icon:icon
                                                                                 userInfo:nil];
        app.shortcutItems = @[item];
    }
}


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    [self addUploadTab];

    // If the app isn’t already loaded, it’s launched and passes details of the shortcut item in through the connectionOptions parameter of the scene:willConnectToSession:options: function.

    if(connectionOptions.shortcutItem != nil) {
        NSLog(@"App launched. connectionOptions = %@", connectionOptions);
        [self handleLaunchFromShortcutItem:connectionOptions.shortcutItem];
    }
}

- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    // If your app is already loaded, the system calls the windowScene:performActionForShortcutItem:completionHandler: function of your scene delegate.
    NSLog(@"Quick Action requested when app already loaded");
    NSLog(@"shortcutItem = %@", shortcutItem);
    
    [self handleLaunchFromShortcutItem:shortcutItem];
}

- (void)handleLaunchFromShortcutItem:(UIApplicationShortcutItem *)shortcutItem {
    if([shortcutItem.type isEqualToString:@"stop"]) {
        [[GLManager sharedManager] endTrip];
    } else {
        [GLManager sharedManager].currentTripMode = shortcutItem.type;
        [[GLManager sharedManager] startTrip];
    }
}


@end

