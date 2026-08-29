#import "GLModuleRegistry.h"
#import "GLTheme.h"

#pragma mark - More-list theming

// The system "More" list (tabBarController.moreNavigationController) is a
// UITableView UIKit builds and owns — there is no dataSource/delegate of ours
// to set on it, and UIKit re-creates its cells fresh on every appearance
// (including navigating into a module and back), so styling it once here at
// install time would not stick. UINavigationControllerDelegate is the one
// hook UIKit exposes on moreNavigationController itself, and it fires on
// every push AND pop of that navigation controller — including the very
// first time the user opens More (UITabBarController pushes the list
// controller onto moreNavigationController the first time it's needed,
// rather than only setting it as the root) and every time they return to it
// from a module — so restyling from here survives exactly the navigation the
// brief calls out.
@interface GLMoreListThemer : NSObject <UINavigationControllerDelegate>
@end

@implementation GLMoreListThemer

// Every module's own root VC carries a "GLModule.<class>" restoration
// identifier (see +makeViewControllers below) — skip those and theme only
// the identifier-less system list, so a module that ever pushes its own
// table-based screen onto moreNavigationController isn't double-styled by
// this hook. `hasPrefix:` on a nil identifier (the system list's case) is a
// safe no-op message send, not a crash.
- (BOOL)isMoreListViewController:(UIViewController *)viewController {
    if ([viewController.restorationIdentifier hasPrefix:@"GLModule."]) {
        return NO;
    }
    return [viewController.view isKindOfClass:[UITableView class]];
}

- (void)themeMoreListViewController:(UIViewController *)viewController {
    UITableView *table = (UITableView *)viewController.view;
    table.backgroundColor = [GLTheme backgroundColor];
    table.separatorColor = [GLTheme textSecondaryColor];
    for (UITableViewCell *cell in table.visibleCells) {
        cell.backgroundColor = [GLTheme surfaceColor];
        cell.textLabel.textColor = [GLTheme textPrimaryColor];
    }
}

- (void)navigationController:(UINavigationController *)navigationController
       willShowViewController:(UIViewController *)viewController
                     animated:(BOOL)animated {
    // Background/separator can be set before the cells exist yet.
    if ([self isMoreListViewController:viewController]) {
        [self themeMoreListViewController:viewController];
    }
}

- (void)navigationController:(UINavigationController *)navigationController
        didShowViewController:(UIViewController *)viewController
                      animated:(BOOL)animated {
    // Cells are only guaranteed to exist (non-empty visibleCells) once the
    // view has actually finished appearing, which is here, not in
    // -willShowViewController: above.
    if ([self isMoreListViewController:viewController]) {
        [self themeMoreListViewController:viewController];
    }
}

@end

@implementation GLModuleRegistry

// Backing store for +registerModule:. A function-local static rather than a
// class-level static/ivar on purpose: +load runs during image loading, before
// main(), in an order that is undefined across classes — GLModuleRegistry's
// own +load (it has none) is not guaranteed to run before a module's +load
// fires +registerModule:. A function-local static inside a C function is
// created lazily on first call regardless of which class triggers it first,
// so there is no dependency on GLModuleRegistry having initialized anything.
static NSMutableArray *GLRegisteredModules(void) {
    static NSMutableArray *modules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        modules = [NSMutableArray array];
    });
    return modules;
}

+ (void)registerModule:(Class)module {
    [GLRegisteredModules() addObject:module];
}

+ (NSArray *)moduleClasses {
    // Modules used to be found by walking every class in the process
    // (objc_copyClassList) and keeping the ones that conform to GLModule.
    // That walk *realizes* every class it touches — UIKit, Foundation,
    // AFNetworking, all of it — just to ask whether each one conforms to a
    // protocol, and profiling showed it was 1,443ms of a 3,255ms cold launch,
    // the single largest phase in the app. Modules now self-register from
    // their own +load instead (see +registerModule: and GLRegisteredModules
    // above), so this only ever sorts a small, already-known list.
    //
    // +load runs for every module class before main() runs, and the first
    // call to +moduleClasses happens from didFinishLaunchingWithOptions: (via
    // SceneDelegate/AppDelegate), which is always after main() — so by the
    // time this dispatch_once body runs, every module's +load has already
    // registered it. Caching here is still safe for the same reason it was
    // before: module membership can't change after launch.
    static NSArray *cachedModules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *registered = GLRegisteredModules();
        if (registered.count == 0) {
            [NSException raise:NSInternalInconsistencyException
                        format:@"GLModuleRegistry has no registered modules — "
                                "a GLModule conformer is likely missing its "
                                "+load self-registration (see MODULES.md)"];
        }

        // Order is part of the contract: two sessions that independently
        // pick the same +moduleOrder must still produce the same tab bar on
        // every launch, so class name is the tiebreak rather than +load
        // registration order (which, across classes, is undefined).
        NSArray *sorted = [registered sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSInteger orderA = [(Class)a moduleOrder];
            NSInteger orderB = [(Class)b moduleOrder];
            if (orderA != orderB) {
                return orderA < orderB ? NSOrderedAscending : NSOrderedDescending;
            }
            return [NSStringFromClass((Class)a) compare:NSStringFromClass((Class)b)];
        }];
        cachedModules = [sorted copy];
    });
    return cachedModules;
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

    // A UINavigationController's `delegate` is weak, so a themer created and
    // dropped here would be deallocated before the user ever taps More. Keep
    // one alive for the process's lifetime, same dispatch_once pattern as
    // GLRegisteredModules above.
    static GLMoreListThemer *moreListThemer;
    static dispatch_once_t themerOnceToken;
    dispatch_once(&themerOnceToken, ^{
        moreListThemer = [[GLMoreListThemer alloc] init];
    });
    tabs.moreNavigationController.delegate = moreListThemer;

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

+ (void)notifyModulesDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSMutableArray<NSString *> *responded = [NSMutableArray array];
    for (Class module in [self moduleClasses]) {
        if ([module respondsToSelector:@selector(moduleDidFinishLaunchingWithOptions:)]) {
            [module moduleDidFinishLaunchingWithOptions:launchOptions];
            [responded addObject:NSStringFromClass(module)];
        }
    }
    // Liveness signal for the launch fan-out, mirroring the installed-tabs
    // log line below: if a module's hook were ever renamed out from under
    // this selector, launch setup, URL/activity/shortcut routing and the
    // diagnostic would all silently stop firing while the tab still
    // appeared. CI asserts on this line the same way it asserts on the
    // installed-tabs line.
    NSLog(@"Module registry: launch hooks fired for %lu modules: %@",
          (unsigned long)responded.count, [responded componentsJoinedByString:@", "]);
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

+ (BOOL)routeUserActivity:(NSUserActivity *)activity {
    for (Class module in [self moduleClasses]) {
        if ([module respondsToSelector:@selector(moduleHandleUserActivity:)] &&
            [module moduleHandleUserActivity:activity]) {
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
    NSLog(@"Module registry: no module claimed shortcut item type=%@", item.type);
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

#pragma mark - App-lifecycle fan-out

+ (void)startObservingAppLifecycle {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        [nc addObserverForName:UISceneDidEnterBackgroundNotification
                         object:nil
                          queue:nil
                     usingBlock:^(NSNotification *note) {
            for (Class module in [self moduleClasses]) {
                if ([module respondsToSelector:@selector(moduleDidEnterBackground)]) {
                    [module moduleDidEnterBackground];
                }
            }
        }];

        [nc addObserverForName:UISceneWillEnterForegroundNotification
                         object:nil
                          queue:nil
                     usingBlock:^(NSNotification *note) {
            for (Class module in [self moduleClasses]) {
                if ([module respondsToSelector:@selector(moduleWillEnterForeground)]) {
                    [module moduleWillEnterForeground];
                }
            }
        }];

        [nc addObserverForName:UISceneWillDeactivateNotification
                         object:nil
                          queue:nil
                     usingBlock:^(NSNotification *note) {
            for (Class module in [self moduleClasses]) {
                if ([module respondsToSelector:@selector(moduleWillResignActive)]) {
                    [module moduleWillResignActive];
                }
            }
        }];
    });
}

@end
