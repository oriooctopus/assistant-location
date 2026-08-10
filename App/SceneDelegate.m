//
//  SceneDelegate.m
//  Overland
//
//  Created by Aaron Parecki on 12/10/23.
//  Copyright © 2023 Aaron Parecki. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "SceneDelegate.h"
#import "GLModuleRegistry.h"
#import "GLTheme.h"
#import "GLDefaultsKeys.h"
#import "BuildStamp.generated.h"

@implementation SceneDelegate

#pragma mark - First-launch build diagnostic

// Presented from the scene delegate, on the window's root view controller,
// deliberately: the previous build markers all lived inside a custom view and
// none of them were readable on the device. A UIAlertController owns its own
// window-level presentation, so it shows up whether or not the app's own views
// draw anything useful.
- (void)presentBuildDiagnosticIfNeeded:(UIScene *)scene {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *shown = [defaults stringForKey:GLBuildAlertShownStampDefaultsName];
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

    // build stamp / bundle version / app name are shell-owned facts; the
    // endpoint / token / auth lines are module-owned and sourced through the
    // registry so this file no longer needs to know which module (if any)
    // has network/location state to report.
    NSString *moduleLines = [GLModuleRegistry diagnosticSummary];

    NSString *body = [NSString stringWithFormat:
                      @"build stamp: %@\n"
                      @"bundle version: %@\n"
                      @"app name: %@\n\n"
                      @"%@",
                      GL_BUILD_STAMP,
                      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],
                      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"],
                      moduleLines];

    NSLog(@"Build diagnostic: %@", [body stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Build Identity"
                                            message:body
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [defaults setObject:GL_BUILD_STAMP forKey:GLBuildAlertShownStampDefaultsName];
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

    // Test hook (same pattern as UITEST_TAB above): simulate the Control
    // Center "start journal capture" path, which XCUITest can't trigger
    // directly since Control Center is outside the app sandbox. Posts the
    // same notification AutoJournalModule +moduleHandleURL: posts when the
    // Control's overland://journal/voice URL arrives, after a short delay so
    // AutoJournalViewController has finished -init (where it registers its
    // observer) and is on-screen. NOTE this deliberately starts from the
    // notification, so it does NOT exercise the Control -> URL -> scene
    // routing hop — see JournalControlUITest.swift's scope comment.
    if([[NSProcessInfo processInfo] environment][@"UITEST_JOURNAL_AUTOSTART"] != nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"GLJournalStartCapture"
                                                                  object:nil];
        });
    }

    // Slight delay so the root view controller has finished its own
    // presentation work before the diagnostic goes up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self presentBuildDiagnosticIfNeeded:scene];
    });
}

// sceneWillEnterForeground / sceneDidEnterBackground / sceneWillResignActive
// used to live here and drove module-specific behavior directly. That work
// now lives inside whichever module cares, which observes the equivalent
// UISceneWillEnterForegroundNotification / UISceneDidEnterBackgroundNotification
// / UISceneWillDeactivateNotification itself — see the Tracker module's
// app-lifecycle observer for an example. This file has nothing left to do at
// those three lifecycle points.

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    UIOpenURLContext *context = [URLContexts anyObject];
    [GLModuleRegistry routeURL:context.URL];
}

#pragma mark - Modules

// The tab bar is assembled at runtime from every class conforming to GLModule
// (see MODULES.md). The storyboard still owns the Tracker and Settings LAYOUTS
// — its tab bar controller is an empty shell — so adding a tab needs no
// storyboard edit, no central registry and no project.pbxproj entry, and two
// sessions can add tabs at the same time without sharing a file.
- (void)installModules {
    UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
    if(![tabs isKindOfClass:[UITabBarController class]]) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Root view controller is %@, not a UITabBarController; "
                           @"Main.storyboard's initial view controller must stay a tab bar controller",
                           tabs.class];
    }
    [GLModuleRegistry installIntoTabBarController:tabs];
}

#pragma mark - Quick Actions

// https://developer.apple.com/documentation/uikit/menus_and_shortcuts/add_home_screen_quick_actions?language=objc
//
// Registering the actual UIApplicationShortcutItem array is module-specific
// and now happens inside whichever module owns it, triggered off its own
// lifecycle notification observer. This file only routes shortcut
// activations to whichever module claims them.

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // A newly connected scene's window doesn't yet have the persisted
    // appearance override applied — AppDelegate's launch-time call only
    // reaches scenes that already existed at that point (there are none on
    // cold launch), so a scene created after launch needs it applied here.
    [GLTheme applyCurrentMode];

    [self installModules];

    // If the app isn’t already loaded, it’s launched and passes details of the shortcut item in through the connectionOptions parameter of the scene:willConnectToSession:options: function.

    if(connectionOptions.shortcutItem != nil) {
        NSLog(@"App launched. connectionOptions = %@", connectionOptions);
        [GLModuleRegistry routeShortcutItem:connectionOptions.shortcutItem];
    }
}

- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    // If your app is already loaded, the system calls the windowScene:performActionForShortcutItem:completionHandler: function of your scene delegate.
    NSLog(@"Quick Action requested when app already loaded");
    NSLog(@"shortcutItem = %@", shortcutItem);

    [GLModuleRegistry routeShortcutItem:shortcutItem];
}

@end
