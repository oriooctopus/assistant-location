#import "GLModuleRegistry.h"

#import <objc/runtime.h>

@implementation GLModuleRegistry

+ (NSArray *)moduleClasses {
    // class_conformsToProtocol() reads the class's own protocol list rather
    // than sending it a message, so walking the whole runtime is safe even
    // for classes that cannot be messaged. It also does not consult
    // superclasses, so a subclass of a module is not registered twice.
    Protocol *contract = @protocol(GLModule);
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    NSMutableArray *modules = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        if (class_conformsToProtocol(all[i], contract)) {
            [modules addObject:all[i]];
        }
    }
    free(all);

    // Order is part of the contract: two sessions that independently pick the
    // same +moduleOrder must still produce the same tab bar on every launch,
    // so class name is the tiebreak rather than runtime registration order.
    [modules sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger orderA = [(Class)a moduleOrder];
        NSInteger orderB = [(Class)b moduleOrder];
        if (orderA != orderB) {
            return orderA < orderB ? NSOrderedAscending : NSOrderedDescending;
        }
        return [NSStringFromClass((Class)a) compare:NSStringFromClass((Class)b)];
    }];
    return modules;
}

+ (NSArray<UIViewController *> *)makeViewControllers {
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    for (Class module in [self moduleClasses]) {
        UIViewController *vc = [module makeViewController];
        if (vc == nil) {
            [NSException raise:NSInternalInconsistencyException
                        format:@"%@ +makeViewController returned nil", module];
        }
        vc.title = [module moduleTitle];
        vc.tabBarItem = [[UITabBarItem alloc] initWithTitle:[module moduleTitle]
                                                      image:[module moduleIcon]
                                                        tag:0];
        // Index-independent identity, for anything that needs to find a tab.
        vc.restorationIdentifier =
            [NSString stringWithFormat:@"GLModule.%@", NSStringFromClass(module)];
        [controllers addObject:vc];
    }
    return controllers;
}

+ (void)installIntoTabBarController:(UITabBarController *)tabs {
    NSArray<UIViewController *> *controllers = [self makeViewControllers];
    tabs.viewControllers = controllers;

    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (UIViewController *vc in controllers) {
        [titles addObject:vc.title];
    }
    NSLog(@"Module registry: installed %lu tabs: %@",
          (unsigned long)controllers.count, [titles componentsJoinedByString:@", "]);
}

#pragma mark - Optional-hook fan-out
//
// All three of these walk the same +moduleClasses list makeViewControllers
// uses above — one discovery/sort implementation, several fan-outs over it.
// Every call is guarded with respondsToSelector: since the hooks are
// @optional in GLModule.h.

+ (void)notifyModulesDidFinishLaunching {
    for (Class module in [self moduleClasses]) {
        if ([module respondsToSelector:@selector(moduleDidFinishLaunching)]) {
            [module moduleDidFinishLaunching];
        }
    }
}

+ (BOOL)routeURL:(NSURL *)url {
    for (Class module in [self moduleClasses]) {
        if ([module respondsToSelector:@selector(moduleHandleURL:)] &&
            [module moduleHandleURL:url]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)routeShortcutItem:(UIApplicationShortcutItem *)item {
    for (Class module in [self moduleClasses]) {
        if ([module respondsToSelector:@selector(moduleHandleShortcutItem:)] &&
            [module moduleHandleShortcutItem:item]) {
            return YES;
        }
    }
    return NO;
}

+ (NSString *)diagnosticSummary {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (Class module in [self moduleClasses]) {
        if ([module respondsToSelector:@selector(moduleDiagnosticSummary)]) {
            NSString *summary = [module moduleDiagnosticSummary];
            if (summary.length > 0) {
                [lines addObject:summary];
            }
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end
