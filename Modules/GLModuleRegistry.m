#import "GLModuleRegistry.h"

#import <objc/runtime.h>

@implementation GLModuleRegistry

+ (NSArray<Class> *)moduleClasses {
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
    [modules sortUsingComparator:^NSComparisonResult(Class a, Class b) {
        NSInteger orderA = [a moduleOrder];
        NSInteger orderB = [b moduleOrder];
        if (orderA != orderB) {
            return orderA < orderB ? NSOrderedAscending : NSOrderedDescending;
        }
        return [NSStringFromClass(a) compare:NSStringFromClass(b)];
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

@end
