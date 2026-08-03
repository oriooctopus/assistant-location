//
//  AppDelegate.m
//  App
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//

#import "AppDelegate.h"
#import "GLModuleRegistry.h"
#import "GLTheme.h"
#import "GLLaunchTrace.h"

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
    GLLaunchMark(@"will-finish-launching");
    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    GLLaunchMark(@"did-finish-launching:begin");

    NSLog(@"Application launched with options: %@", launchOptions);

    // Shared platform layer, applied before any module runs: the appearance
    // override needs to be on the window before a module's first view loads,
    // and the lifecycle fan-out needs to be observing before background/
    // foreground/resign events can happen. Neither depends on a feature
    // module — GLTheme and GLModuleRegistry are shared infrastructure.
    [GLTheme applyCurrentMode];
    GLLaunchMark(@"did-finish-launching:after-theme");
    [GLModuleRegistry startObservingAppLifecycle];
    GLLaunchMark(@"did-finish-launching:after-lifecycle-observers");

    // Fan out to every module's own one-time launch setup (baked config,
    // first-launch auto-enable, migrations, etc). launchOptions is passed
    // through unmodified — this shell attaches no meaning to any key in it,
    // including whatever reason UIKit relaunched the app for. See GLModule.h.
    [GLModuleRegistry notifyModulesDidFinishLaunchingWithOptions:launchOptions];
    GLLaunchMark(@"did-finish-launching:after-module-fanout");

    GLLaunchMark(@"did-finish-launching:end");
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
    // UIKit also posts UIApplicationWillTerminateNotification around this
    // same call, which is what any module that needs to react (e.g. flush
    // location state) observes for itself — see GLModule.h's fan-out design.
    NSLog(@"Application is terminating");
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> * _Nullable))restorationHandler
{
    // The activity is passed through unmodified — this shell has no opinion
    // on what any given activity type means; whichever module owns a
    // Siri/Handoff continuation inspects userActivity.activityType itself.
    // See GLModule.h's +moduleHandleUserActivity:.
    return [GLModuleRegistry routeUserActivity:userActivity];
}

@end
