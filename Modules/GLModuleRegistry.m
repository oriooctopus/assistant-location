#import "GLModuleRegistry.h"
#import "GLTheme.h"
#import "GLWebModuleViewController.h"

#pragma mark - The More stack

// UITabBarController shows at most five tabs and pushes everything past the
// fourth into a "More" bucket: a navigation controller whose root is a plain
// table list UIKit builds and owns. That list was the worst-looking screen in
// the app — rows crammed against the tab bar with the last one clipped by it,
// two thirds of the screen empty above them, a surface-coloured slab against
// a differently-coloured page, and a stray "Edit" button for customising a
// tab order nothing else here honours. An earlier pass tried to restyle it
// from this file; it could not be made good, because UIKit rebuilds the
// table's cells on every appearance and the layout was never ours to choose.
// A second pass replaced it with GLMoreGridViewController, a native grid --
// still not restyling UIKit's list, but still a native screen.
//
// It is now a THIRD screen: a GLWebModuleViewController wrapping the bundled
// "more.html" page becomes the root of moreNavigationController, and neither
// the system list nor GLMoreGridViewController ever appears (that class'
// files stay in the tree, unused, for now). The tap/drag/reorder behaviour
// that used to live in GLMoreGridViewController now lives in more.html +
// GLWebBridge; this file's job shrinks to holding the ROOT in place across
// UIKit's own list-resets and to the identifier -> view-controller lookup
// +openOverflowModuleWithIdentifier: below runs for both the web page's
// `openModule` bridge call and the UITEST_MORE_TILE test hook.
//
// Replacing only the ROOT — rather than restructuring the tab bar so the
// grid is a fifth tab of its own — is deliberate. Every module keeps the tab
// INDEX it has today, so SceneDelegate's UITEST_TAB hook, sim-test's
// TAB_ENTRIES, AutoJournal's -selectJournalTab (which finds itself by index
// in tabs.viewControllers) and the module view controllers' own structure
// (Journal wraps itself in a navigation controller, which UIKit's More stack
// already tolerated) all keep working untouched. A tile "open" goes onto
// exactly the navigation controller UIKit would have pushed onto anyway.
@interface GLMoreStackCoordinator : NSObject <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) GLWebModuleViewController *root;
@property (nonatomic, strong) NSArray<UIViewController *> *overflowModules;
@property (nonatomic, weak) UINavigationController *moreNav;
- (void)takeOverNavigationController:(UINavigationController *)navigationController;
@end

@implementation GLMoreStackCoordinator

- (void)takeOverNavigationController:(UINavigationController *)navigationController {
    self.moreNav = navigationController;
    navigationController.delegate = self;
    // Always hidden, on every screen in this stack. The web root draws its
    // own "More" heading, and a module reached from here must look exactly
    // like a module reached from a tab — which has no navigation controller
    // at all, and so no bar. The user, on the old behaviour: "there's an
    // extra header at the top with a back button. That shouldn't happen.
    // It's like with any of the other tabs."
    //
    // Two ways back to the root survive the hidden bar: tapping the
    // already-selected More tab pops this navigation controller to its root
    // (UITabBarController's standard behaviour for any nav controller in a
    // tab), and the left-edge swipe still works because we take over
    // interactivePopGestureRecognizer's delegate below — UIKit otherwise
    // disables that gesture whenever the bar is hidden.
    navigationController.navigationBarHidden = YES;
    navigationController.interactivePopGestureRecognizer.delegate = self;
    [self installRootIfNeeded];
}

// UIKit builds its own list lazily, and rebuilds it whenever it decides the
// More stack needs resetting — notably when someone sets `selectedIndex` to
// an index past the visible tabs, which replaces the whole stack with
// [systemList, targetModule]. So planting the root once at launch is not
// enough; this re-plants it as the root whenever UIKit has put its list
// back, and is called from both navigation callbacks below. Any module
// already pushed on top is preserved, so a reset mid-navigation does not
// throw the user back to the More page.
- (void)installRootIfNeeded {
    UINavigationController *nav = self.moreNav;
    if (nav == nil || self.root == nil) return;
    NSArray<UIViewController *> *stack = nav.viewControllers;
    if (stack.firstObject == self.root) return;
    NSMutableArray<UIViewController *> *replacement = [stack mutableCopy];
    if (replacement.count == 0) {
        [replacement addObject:self.root];
    } else {
        replacement[0] = self.root;
    }
    [nav setViewControllers:replacement animated:NO];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.moreNav.interactivePopGestureRecognizer) {
        return YES;
    }
    // Never YES on a single-controller stack — that is the classic way to
    // wedge a navigation controller into an unrecoverable state.
    return self.moreNav.viewControllers.count > 1;
}

- (void)navigationController:(UINavigationController *)navigationController
       willShowViewController:(UIViewController *)viewController
                     animated:(BOOL)animated {
    // Re-asserted rather than trusted: UIKit re-shows its own bar as part of
    // the same stack reset that re-inserts the system list.
    if (!navigationController.navigationBarHidden) {
        [navigationController setNavigationBarHidden:YES animated:animated];
    }
    // Re-asserted here for a different reason: at -takeOverNavigationController:
    // time this navigation controller's view has not loaded yet, and
    // `interactivePopGestureRecognizer` is nullable until it has — so the
    // assignment there lands on nil and the back-swipe stays dead. (The
    // deleted GLMoreListThemer re-asserted on every willShow, which is why
    // it worked before.) Assigning the same delegate repeatedly is a no-op.
    navigationController.interactivePopGestureRecognizer.delegate = self;
    // Deliberately NOT re-planting the root here: -installRootIfNeeded calls
    // -setViewControllers:, and mutating a navigation stack part-way through
    // its own push transition is how you get UIKit into an inconsistent
    // state. -didShow: below runs after the transition and is enough,
    // because the only thing that resets this stack (setting selectedIndex
    // past the visible tabs) always pushes a module on top — so UIKit's list
    // sits at index 0, off-screen, and is swapped out before it can ever be
    // seen.
}

- (void)navigationController:(UINavigationController *)navigationController
        didShowViewController:(UIViewController *)viewController
                      animated:(BOOL)animated {
    [self installRootIfNeeded];
}

@end

// File-scope rather than a static local inside +installIntoTabBarController:,
// so +openMoreTileWithIdentifier: below can reach the same instance. A
// UINavigationController's `delegate` is weak, so this reference is also
// what keeps the coordinator alive for the process's lifetime.
static GLMoreStackCoordinator *moreCoordinator;


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

    // Anything past the fourth module is in UIKit's More bucket. Five is
    // UITabBarController's own limit on iPhone (four real tabs plus the
    // "More" item), so this is the split UIKit has already made by the time
    // the line above returns — not a preference of ours. With four modules
    // or fewer there is no bucket and nothing to replace.
    NSUInteger const visibleTabCount = 4;
    if (controllers.count > visibleTabCount + 1) {
        NSArray<UIViewController *> *overflow =
            [controllers subarrayWithRange:NSMakeRange(visibleTabCount,
                                                       controllers.count - visibleTabCount)];

        // A UINavigationController's `delegate` is weak, so a coordinator
        // created and dropped here would be deallocated before the user ever
        // taps More. Keep one alive for the process's lifetime, same
        // dispatch_once pattern as GLRegisteredModules above.
        static dispatch_once_t coordinatorOnceToken;
        dispatch_once(&coordinatorOnceToken, ^{
            moreCoordinator = [[GLMoreStackCoordinator alloc] init];
        });
        moreCoordinator.overflowModules = overflow;
        moreCoordinator.root =
            [[GLWebModuleViewController alloc] initWithBundledPageNamed:@"more.html"];
        [moreCoordinator takeOverNavigationController:tabs.moreNavigationController];

        NSMutableArray<NSString *> *tileTitles = [NSMutableArray array];
        for (UIViewController *vc in overflow) [tileTitles addObject:vc.title];
        NSLog(@"Module registry: More page holds %lu tiles: %@",
              (unsigned long)overflow.count, [tileTitles componentsJoinedByString:@", "]);
    }

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

#pragma mark - Default tab

+ (BOOL)selectDefaultTabInTabBarController:(UITabBarController *)tabs {
    NSArray *modules = [self moduleClasses];
    NSArray<UIViewController *> *controllers = tabs.viewControllers;
    NSUInteger index = 0;
    for (Class module in modules) {
        if ([module respondsToSelector:@selector(moduleIsDefaultTab)] &&
            [module moduleIsDefaultTab]) {
            // module index N == view-controller index N: +makeViewControllers
            // builds exactly one controller per entry of +moduleClasses, in
            // the same order (see its implementation above). Guarded rather
            // than trusted blindly, so a future refactor that breaks that
            // invariant fails loudly here instead of indexing out of bounds.
            if (index >= controllers.count) {
                [NSException raise:NSInternalInconsistencyException
                            format:@"%@ opted into +moduleIsDefaultTab at module "
                                    "index %lu, but tabs.viewControllers only has "
                                    "%lu entries",
                                    module, (unsigned long)index,
                                    (unsigned long)controllers.count];
            }
            tabs.selectedIndex = index;
            NSLog(@"Module registry: default tab -> %@ (index %lu)",
                  [module moduleTitle], (unsigned long)index);
            return YES;
        }
        index++;
    }
    return NO;
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


#pragma mark - The More overflow: shared identifier lookup + open logic

// The exact logic GLMoreGridViewController's own -openModuleViewController:
// used to run for a tile tap, moved here now that the More screen's root is
// a web page rather than that grid, and defined FIRST in this section (ahead
// of its only caller, +openOverflowModuleWithIdentifier: below) purely so
// this file never needs a forward declaration for it -- Objective-C
// resolves an undeclared selector against implementations already parsed
// earlier in the same @implementation, not ones still to come.
// +openOverflowModuleWithIdentifier: is itself reached from TWO places --
// GLWebBridge's `openModule` handler and +openMoreTileWithIdentifier: below
// -- which is exactly why the select-vs-push decision lives here as one
// paragraph instead of being copied into both.
//
// A module that wraps itself in its own UINavigationController (Journal
// does, so it can push its "Recent" screen) must NOT be pushed:
// -pushViewController: raises NSInvalidArgumentException, "Pushing a
// navigation controller is not supported". UIKit's own former More list
// never pushed one either — it SELECTED it, which is also what
// AutoJournalViewController's -selectJournalTab and SceneDelegate's
// UITEST_TAB hook do, and the path CI has been screenshotting all along.
+ (BOOL)openModuleViewController:(nullable UIViewController *)module
         ontoNavigationController:(nullable UINavigationController *)navigationController {
    if (module == nil) return NO;
    if ([module isKindOfClass:[UINavigationController class]]) {
        UITabBarController *tabs = navigationController.tabBarController;
        if (tabs != nil && [tabs.viewControllers containsObject:module]) {
            tabs.selectedViewController = module;
            return YES;
        }
        return NO;
    }
    if (navigationController == nil) return NO;
    [navigationController pushViewController:module animated:YES];
    return YES;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)overflowModuleDescriptors {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *descriptors = [NSMutableArray array];
    for (UIViewController *vc in moreCoordinator.overflowModules) {
        [descriptors addObject:@{
            @"identifier": vc.restorationIdentifier ?: @"",
            @"title": vc.title ?: @"",
        }];
    }
    return descriptors;
}

+ (BOOL)openOverflowModuleWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    UIViewController *target = nil;
    for (UIViewController *vc in moreCoordinator.overflowModules) {
        if ([vc.restorationIdentifier isEqualToString:identifier]) {
            target = vc;
            break;
        }
    }
    return [self openModuleViewController:target ontoNavigationController:moreCoordinator.moreNav];
}

#pragma mark - Test hooks

+ (BOOL)openMoreTileWithIdentifier:(NSString *)identifier {
    // Thin wrapper: this identifier -> open-module path is no longer
    // test-only (GLWebBridge's `openModule` handler runs through the exact
    // same +openOverflowModuleWithIdentifier: above), but the name stays for
    // SceneDelegate's UITEST_MORE_TILE hook and sim-test.yml's tile loop,
    // which already call it by this name.
    return [self openOverflowModuleWithIdentifier:identifier];
}

@end
