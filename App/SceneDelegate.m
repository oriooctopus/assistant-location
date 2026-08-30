//
//  SceneDelegate.m
//  Overland
//
//  Created by Aaron Parecki on 12/10/23.
//  Copyright © 2023 Aaron Parecki. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime, for the resume-threshold clock below.

#import "SceneDelegate.h"
#import "GLModuleRegistry.h"
#import "GLTheme.h"
#import "GLDefaultsKeys.h"
#import "GLEndpoints.h"
#import "GLAppStateReporter.h"
#import "BuildStamp.generated.h"

// How long the app has to have been backgrounded before a foreground resume
// resets to the default tab — a quick app-switch must not yank the user off
// whatever tab they were on, but a real absence should. Overridable so
// sim-test can drive both the "long absence" and "quick switch" paths
// without an actual multi-minute wait (see UITEST_RESUME_THRESHOLD_SECONDS
// in sim-test.yml).
static NSTimeInterval const kGLDefaultTabResumeThresholdSecondsDefault = 180.0;

static NSTimeInterval GLDefaultTabResumeThresholdSeconds(void) {
    NSString *override = [[NSProcessInfo processInfo] environment][@"UITEST_RESUME_THRESHOLD_SECONDS"];
    if (override.length > 0) {
        return [override doubleValue];
    }
    return kGLDefaultTabResumeThresholdSecondsDefault;
}

@interface SceneDelegate ()
// CACurrentMediaTime() at the last -sceneDidEnterBackground:, or 0 if the
// scene has never been backgrounded (e.g. a cold launch, which also invokes
// -sceneWillEnterForeground: — see there). CACurrentMediaTime is a monotonic
// clock, unlike NSDate/[NSDate date], so a clock change (DST, NTP, a manual
// clock set) while backgrounded can't move it.
@property (nonatomic, assign) CFTimeInterval gl_backgroundedAtMediaTime;
@end

// TEMPORARY — same fire-and-forget server log as AutoJournalViewController's
// journalDebugLog:, duplicated here so URL *arrival* is visible separately
// from the notification handler running. Delete together with the /debug-log
// endpoint once the Control chain is confirmed working.
static void GLSceneDebugLog(NSString *message) {
    // GLEndpointURL raises when GL_BAKED_HOST is unbaked (always true for
    // sim-test's CI build — see SettingsViewController.m), which was
    // crashing the app on every cold launch, before it ever rendered a
    // frame. This is the actual precondition GLEndpointURL checks; guard on
    // it explicitly and return (no @try/@catch — that would also hide a
    // real bug in this code path, which is exactly how this one went
    // unnoticed for months) so the fire-and-forget contract holds without
    // swallowing anything unexpected.
    if (GL_BAKED_HOST.length == 0 || [GL_BAKED_HOST isEqualToString:@"NO_HOST_BAKED_IN"]) {
        NSLog(@"GLSceneDebugLog: inert, GL_BAKED_HOST is unbaked");
        return;
    }
    NSString *encoded = [message stringByAddingPercentEncodingWithAllowedCharacters:
                          [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"?msg=%@", encoded]
                         relativeToURL:GLEndpointURL(@"/debug-log")];
    [[[NSURLSession sharedSession] dataTaskWithURL:url] resume];
}

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
            UITabBarController *tabs = (UITabBarController *)root;
            // "more" selects the More tab itself rather than a module.
            // Selecting by index can't reach it: an index past the visible
            // tabs opens that module's own screen, never the More screen.
            // That screen is no longer UIKit's list — GLMoreGridViewController
            // replaces it as the root of moreNavigationController (see
            // GLModuleRegistry) — so this is what screenshots the grid.
            if([tab isEqualToString:@"more"]) {
                tabs.selectedViewController = tabs.moreNavigationController;
            } else {
                tabs.selectedIndex = [tab integerValue];
            }
        }
    }

    // Test hook: open one More-grid TILE, by the module's restoration
    // identifier (e.g. "GLModule.AutoJournalModule"), through the same code
    // path a finger does. UITEST_TAB above cannot cover this: it sets
    // `selectedIndex`, which is UIKit's own routing, whereas a tile tap runs
    // the grid's handler — and that handler is where a module wrapping
    // itself in a UINavigationController (Journal) raises if it is pushed
    // rather than selected. Without this, no screenshot test touches the one
    // piece of the More screen that can crash.
    NSString *moreTile = [[NSProcessInfo processInfo] environment][@"UITEST_MORE_TILE"];
    if (moreTile != nil) {
        UIViewController *root = self.window.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tabs = (UITabBarController *)root;
            // Show the More screen first: the grid only exists once its
            // navigation controller has been taken over, and opening a tile
            // from a different tab would leave the wrong tab selected.
            tabs.selectedViewController = tabs.moreNavigationController;
            // After a turn of the run loop, so the grid's view has loaded and
            // the coordinator has re-planted it as the stack's root.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                BOOL opened = [GLModuleRegistry openMoreTileWithIdentifier:moreTile];
                NSLog(@"UITEST_MORE_TILE %@: %@", moreTile, opened ? @"opened" : @"NO SUCH TILE");
            });
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

    // TEMPORARY baseline signal: proves app-side debug logging works at all
    // on every app open, independent of the Controls. Without this, "zero
    // log lines" can't distinguish "button chain dead" from "logging dead".
    GLSceneDebugLog(@"sceneDidBecomeActive");

    // Slight delay so the root view controller has finished its own
    // presentation work before the diagnostic goes up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self presentBuildDiagnosticIfNeeded:scene];

        // Server-side twin of the alert above: the alert only reaches
        // whoever is looking at the phone right now, which is how a
        // theming bug got verified against the wrong resolved variant for
        // days — nothing about a running install reached the server at
        // all. Same trigger point deliberately, so "did the alert show" and
        // "did the report go out" are always the same launch.
        [GLAppStateReporter report];
    });
}

// sceneWillEnterForeground / sceneDidEnterBackground / sceneWillResignActive
// used to live here and drove module-specific behavior directly. That work
// moved into whichever module cares, which observes the equivalent
// UISceneWillEnterForegroundNotification / UISceneDidEnterBackgroundNotification
// / UISceneWillDeactivateNotification itself — see the Tracker module's
// app-lifecycle observer for an example.
//
// -sceneDidEnterBackground: and -sceneWillEnterForeground: are back below,
// deliberately, despite the note above: selecting a tab is shell-owned (the
// shell owns the UITabBarController), so "was the app away long enough to
// reset to the default tab" cannot be a module's own notification observer
// the way the paragraph above describes — it has to run here. This is not a
// regression of that removal; don't move it back into a module.
// -sceneWillResignActive: still has nothing to do here and stays out.

#pragma mark - Default tab on resume

// Shared by the cold-launch call site in -scene:willConnectToSession:options:
// below and by -sceneWillEnterForeground: here: reads back the outcome
// GLModuleRegistry already applied to `tabs` (its own selectedIndex + the
// view controller's title, which +makeViewControllers already set to
// +moduleTitle) rather than re-deriving which module won, so this file
// doesn't need to know module identities either.
- (void)gl_logDefaultTabOutcome:(BOOL)selected inTabBarController:(UITabBarController *)tabs context:(NSString *)context {
    if (selected) {
        NSInteger idx = tabs.selectedIndex;
        NSString *title = tabs.viewControllers[idx].title;
        NSLog(@"GLDefaultTab: %@ -> %@ (index %ld)", context, title, (long)idx);
    } else {
        NSLog(@"GLDefaultTab: %@ -> kept current tab", context);
    }
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    self.gl_backgroundedAtMediaTime = CACurrentMediaTime();
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    // A cold launch also invokes this callback (willConnectToSession ->
    // sceneWillEnterForeground -> sceneDidBecomeActive, even on first
    // launch), but -sceneDidEnterBackground: has never run yet on a cold
    // launch, so there is no elapsed time to measure and cold launch already
    // selected the default tab itself, below. Skip rather than treat an
    // unset clock as an infinite absence.
    if (self.gl_backgroundedAtMediaTime <= 0) {
        return;
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - self.gl_backgroundedAtMediaTime;
    self.gl_backgroundedAtMediaTime = 0;

    UIViewController *root = self.window.rootViewController;
    if (![root isKindOfClass:[UITabBarController class]]) {
        return;
    }
    UITabBarController *tabs = (UITabBarController *)root;
    NSString *context = [NSString stringWithFormat:@"resume after %.0fs", elapsed];

    if (elapsed < GLDefaultTabResumeThresholdSeconds()) {
        // Below the threshold: a quick app-switch, not a real absence — must
        // NOT yank the user off the tab they were on. Log the outcome
        // without calling into the registry at all, so a quick switch never
        // even touches `tabs.selectedIndex`.
        [self gl_logDefaultTabOutcome:NO inTabBarController:tabs context:context];
        return;
    }

    BOOL selected = [GLModuleRegistry selectDefaultTabInTabBarController:tabs];
    [self gl_logDefaultTabOutcome:selected inTabBarController:tabs context:context];
}

// Warm-app URL delivery. Cold launches do NOT get this callback — their URL
// arrives in connectionOptions.URLContexts inside willConnectToSession
// below; missing that was one of the two bugs that made the lock-screen
// Controls open the app on the default tab.
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    UIOpenURLContext *context = [URLContexts anyObject];
    GLSceneDebugLog([NSString stringWithFormat:@"openURLContexts (warm): %@", context.URL.absoluteString]);
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

    // Default tab, cold launch: after modules are installed (there is no tab
    // bar to select into before that) but before the shortcut-item and URL
    // routing below — a lock-screen Control or shortcut that names a
    // specific tab must still win over this. UITEST_TAB in
    // -sceneDidBecomeActive runs later still and overrides both.
    UIViewController *root = self.window.rootViewController;
    if ([root isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabs = (UITabBarController *)root;
        BOOL selected = [GLModuleRegistry selectDefaultTabInTabBarController:tabs];
        [self gl_logDefaultTabOutcome:selected inTabBarController:tabs context:@"cold launch"];
    }

    // If the app isn’t already loaded, it’s launched and passes details of the shortcut item in through the connectionOptions parameter of the scene:willConnectToSession:options: function.

    if(connectionOptions.shortcutItem != nil) {
        NSLog(@"App launched. connectionOptions = %@", connectionOptions);
        [GLModuleRegistry routeShortcutItem:connectionOptions.shortcutItem];
    }

    // Cold-launch URL delivery: when a URL launches the app from scratch
    // (the normal lock-screen Control case), iOS does NOT call
    // -scene:openURLContexts: — the URL arrives here instead. Routed after
    // installModules so every module's view controller (and its notification
    // observers, registered in -init) already exists.
    UIOpenURLContext *urlContext = connectionOptions.URLContexts.anyObject;
    GLSceneDebugLog([NSString stringWithFormat:@"willConnect: URLContexts count=%lu URL=%@",
                     (unsigned long)connectionOptions.URLContexts.count,
                     urlContext.URL.absoluteString ?: @"(none)"]);
    if(urlContext != nil) {
        [GLModuleRegistry routeURL:urlContext.URL];
    }
}

- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    // If your app is already loaded, the system calls the windowScene:performActionForShortcutItem:completionHandler: function of your scene delegate.
    NSLog(@"Quick Action requested when app already loaded");
    NSLog(@"shortcutItem = %@", shortcutItem);

    [GLModuleRegistry routeShortcutItem:shortcutItem];
}

@end
