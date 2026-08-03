// Runtime discovery of GLModule conformers. See GLModule.h and MODULES.md.

#import <UIKit/UIKit.h>
#import "GLModule.h"

@interface GLModuleRegistry : NSObject

/// Every class conforming to GLModule, sorted by +moduleOrder then class name.
/// Untyped NSArray on purpose: `NSArray<Class>` parses as a protocol qualifier.
+ (NSArray *)moduleClasses;

/// One configured view controller per module, in tab order.
+ (NSArray<UIViewController *> *)makeViewControllers;

/// Replaces `tabs.viewControllers` with the discovered modules and logs the
/// resulting tab bar (CI asserts on that line).
+ (void)installIntoTabBarController:(UITabBarController *)tabs;

#pragma mark - Optional-hook fan-out

/// Calls `+moduleDidFinishLaunching` on every conforming module that
/// implements it, in module order. See GLModule.h.
+ (void)notifyModulesDidFinishLaunching;

/// Offers `url` to `+moduleHandleURL:` on each module in order; stops and
/// returns YES at the first module that returns YES. Returns NO if no
/// module claims the URL.
+ (BOOL)routeURL:(NSURL *)url;

/// Offers `item` to `+moduleHandleShortcutItem:` on each module in order;
/// stops and returns YES at the first module that returns YES. Returns NO
/// if no module claims the item.
+ (BOOL)routeShortcutItem:(UIApplicationShortcutItem *)item;

/// Joins every module's non-empty `+moduleDiagnosticSummary` with "\n", in
/// module order.
+ (NSString *)diagnosticSummary;

@end
