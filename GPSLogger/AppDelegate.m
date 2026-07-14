//
//  AppDelegate.m
//  GPSLogger
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//

#import "AppDelegate.h"
#import "GLManager.h"
#import "NSArray+map.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}

#pragma mark -

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    NSLog(@"Application launched with options: %@", launchOptions);

    // Assistant fork: ship pre-pointed at our own location-ingest server
    // (~/coding/assistant/location-server, port 8302) so there's no manual
    // Settings step on first launch. Only sets it if nothing's configured
    // yet, so it doesn't clobber a value changed later in Settings.
    if ([[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName] == nil) {
        [[NSUserDefaults standardUserDefaults] setObject:@"http://100.103.237.24:8302/overland"
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
    NSString *kDidAutoEnable = @"AssistantDidAutoEnableTracking";
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kDidAutoEnable]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLTrackingStateDefaultsName];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDidAutoEnable];
    }

    [GLManager sharedManager];

    // Explicitly request location permission on launch so the user gets the
    // prompt immediately (WhenInUse first, then Always for background logging).
    [[GLManager sharedManager] requestAuthorizationPermission];

    if([launchOptions objectForKey:UIApplicationLaunchOptionsLocationKey]) {
        [[GLManager sharedManager] logAction:@"application_launched_with_location"];
    }

    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    NSLog(@"Application is terminating");
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[GLManager sharedManager] applicationWillTerminate];
}
           
- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> * _Nullable))restorationHandler
{
    // get Bundle ID and add ...
    NSString *bundleIDStarter = [NSString stringWithFormat:@"%@.startTracking", [[NSBundle mainBundle] bundleIdentifier]];
    
    // Check to make sure it's the correct activity type
    if ([userActivity.activityType isEqualToString:bundleIDStarter])
    {
        NSLog(@"startTracking - called from shortcut");
        
        [[GLManager sharedManager] startAllUpdates];
        
        return YES;
    }
    
    return NO;
}

@end
