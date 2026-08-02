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

@end
