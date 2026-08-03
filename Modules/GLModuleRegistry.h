// Runtime discovery of GLModule conformers. See GLModule.h and MODULES.md.

#import <UIKit/UIKit.h>
#import "GLModule.h"

@interface GLModuleRegistry : NSObject

/// Every registered module class (see +registerModule:), sorted by
/// +moduleOrder then class name.
/// Untyped NSArray on purpose: `NSArray<Class>` parses as a protocol qualifier.
+ (NSArray *)moduleClasses;

/// Called from each module class's own `+load`, once per module, to register
/// it with the registry. Do not call this from anywhere except a module's
/// `+load` — see GLModuleRegistry.m for why load-time self-registration
/// replaced runtime scanning, and MODULES.md for the resulting contract.
+ (void)registerModule:(Class)module;

/// One configured view controller per module, in tab order.
+ (NSArray<UIViewController *> *)makeViewControllers;

/// Replaces `tabs.viewControllers` with the discovered modules and logs the
/// resulting tab bar (CI asserts on that line).
+ (void)installIntoTabBarController:(UITabBarController *)tabs;

#pragma mark - Optional-hook fan-out

/// Calls `+moduleDidFinishLaunchingWithOptions:` on every conforming module
/// that implements it, in module order, passing `launchOptions` through
/// unmodified. Logs which modules responded, in the same style as the
/// installed-tabs log line (CI asserts on it). See GLModule.h.
+ (void)notifyModulesDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions;

/// Offers `url` to `+moduleHandleURL:` on each module in order; stops and
/// returns YES at the first module that returns YES. Returns NO if no
/// module claims the URL.
+ (BOOL)routeURL:(NSURL *)url;

/// Offers `activity` to `+moduleHandleUserActivity:` on each module in
/// order; stops and returns YES at the first module that returns YES.
/// Returns NO if no module claims the activity.
+ (BOOL)routeUserActivity:(NSUserActivity *)activity;

/// Offers `item` to `+moduleHandleShortcutItem:` on each module in order;
/// stops and returns YES at the first module that returns YES. Returns NO
/// if no module claims the item.
+ (BOOL)routeShortcutItem:(UIApplicationShortcutItem *)item;

/// Joins every module's non-empty `+moduleDiagnosticSummary` with "\n", in
/// module order.
+ (NSString *)diagnosticSummary;

#pragma mark - App-lifecycle fan-out

/// Registers observers (once, via dispatch_once) for
/// UISceneDidEnterBackgroundNotification / UISceneWillEnterForegroundNotification /
/// UISceneWillDeactivateNotification and fans each out to every conforming
/// module's +moduleDidEnterBackground / +moduleWillEnterForeground /
/// +moduleWillResignActive, guarded by respondsToSelector:. Call once at
/// launch (idempotent — a second call is a no-op).
+ (void)startObservingAppLifecycle;

@end
