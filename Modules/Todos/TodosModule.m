#import "TodosModule.h"

#import "TodosViewController.h"
#import "GLModuleRegistry.h"
#import "GLWebModuleViewController.h"

// Native entry points into the Todos web app's `window.openAddTodo()` (a
// no-arg global the web app exposes exactly like the pre-existing
// window.openBlackBoxPanel/window.switchTab) that don't go through the page's
// own UI: double-tapping the Todos tab bar item, and a long-press context
// menu on it. Both funnel through -openAddTodo below, which is itself the
// same guarded evaluateJavaScript call GLWebModuleViewController already
// makes for its own native->page pushes (-callWebFunctionIfDefined:).
//
// An instance, not class-side on TodosModule itself: UIGestureRecognizer and
// UIContextMenuInteraction need somewhere to hold the tab bar button view
// plus the specific view controller/tab bar controller instances involved,
// and neither retains its target/delegate strongly. Kept alive for the
// process's lifetime via the same dispatch_once + static pattern
// GLModuleRegistry's own moreCoordinator uses (see GLModuleRegistry.m) and
// for the same reason — UIKit can rebuild the tab bar's button views later,
// but this handler must still be there to re-attach to.
@interface TodosTabBarInteractionHandler : NSObject <UIContextMenuInteractionDelegate>
@property(nonatomic, weak) UIViewController *todosViewController;
@property(nonatomic, weak) UITabBarController *tabBarController;
- (void)installOnTabBarButtonView:(UIView *)buttonView;
@end

@implementation TodosTabBarInteractionHandler

- (void)installOnTabBarButtonView:(UIView *)buttonView {
    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap)];
    doubleTap.numberOfTapsRequired = 2;
    [buttonView addGestureRecognizer:doubleTap];

    [buttonView addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
}

- (void)handleDoubleTap {
    [self openAddTodo];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    __weak TodosTabBarInteractionHandler *weakSelf = self;
    UIMenu * (^actionProvider)(NSArray<UIMenuElement *> *) = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *addTodo = [UIAction actionWithTitle:@"Add Todo"
                                                 image:[UIImage systemImageNamed:@"plus"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *action) {
            [weakSelf openAddTodo];
        }];
        return [UIMenu menuWithTitle:@"" children:@[addTodo]];
    };
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                     previewProvider:nil
                                                      actionProvider:actionProvider];
}

// Single call site for both entry points above. A double-tap/long-press can
// fire from any tab (the Todos button is visible everywhere except when
// Todos itself is pushed into the More overflow — see
// +moduleDidInstallTabBarItemForViewController:inTabBarController: below),
// so this switches to the Todos tab first when it isn't already selected,
// then makes the same guarded window.openAddTodo() call. If Todos has never
// been shown this launch, its WKWebView hasn't loaded the page yet and the
// guard makes this a silent no-op — the same tradeoff
// -pushThemeToPageOrReload already accepts for a page still loading.
- (void)openAddTodo {
    UIViewController *todos = self.todosViewController;
    if (todos == nil) return;
    if (self.tabBarController.selectedViewController != todos) {
        self.tabBarController.selectedViewController = todos;
    }
    if ([todos isKindOfClass:[GLWebModuleViewController class]]) {
        [(GLWebModuleViewController *)todos callWebFunctionIfDefined:@"openAddTodo"];
    }
}

@end

// Kept alive for the process's lifetime — see the class comment above.
static TodosTabBarInteractionHandler *todosTabBarHandler;

// UITabBarItem has no gesture API of its own, so reaching the actual button
// view means walking `tabs.tabBar.subviews`. Matched against
// `tabs.tabBar.items` (not `tabs.viewControllers`) rather than assuming an
// index: `items` only lists what the bar is actually showing — Todos'
// module order (50) keeps it well inside the four visible tabs today, but if
// that ever changed and pushed it into the More overflow, `items` would no
// longer contain its tabBarItem and this correctly finds nothing to attach
// to instead of grabbing the wrong button.
static UIView *GLTabBarButtonView(UITabBarController *tabs, UIViewController *viewController) {
    NSUInteger itemIndex = [tabs.tabBar.items indexOfObject:viewController.tabBarItem];
    if (itemIndex == NSNotFound) return nil;

    // The bar's subviews mix the actual per-item buttons (private
    // UITabBarButton, a UIControl subclass — undocumented but stable since
    // iOS 7) with decoration views (background, selection indicator, etc.)
    // that aren't controls at all. Filtering to UIControl and then sorting
    // by x-position is the standard way to recover "the Nth button" without
    // depending on the private class name.
    NSArray<UIView *> *buttons = [tabs.tabBar.subviews filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
            return [evaluatedObject isKindOfClass:[UIControl class]];
        }]];
    buttons = [buttons sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    if (itemIndex >= buttons.count) return nil;
    return buttons[itemIndex];
}

@implementation TodosModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Todos"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"checklist"]; }

+ (NSInteger)moduleOrder { return 100; }

+ (UIViewController *)makeViewController {
    return [[TodosViewController alloc] init];
}

// Wires the double-tap and long-press "Add Todo" entry points onto this
// module's own tab bar button — see TodosTabBarInteractionHandler above for
// what they both actually call.
+ (void)moduleDidInstallTabBarItemForViewController:(UIViewController *)viewController
                                  inTabBarController:(UITabBarController *)tabs {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        todosTabBarHandler = [[TodosTabBarInteractionHandler alloc] init];
    });
    todosTabBarHandler.todosViewController = viewController;
    todosTabBarHandler.tabBarController = tabs;

    UIView *buttonView = GLTabBarButtonView(tabs, viewController);
    if (buttonView == nil) {
        NSLog(@"TodosModule: no tab bar button view found for double-tap/long-press wiring");
        return;
    }
    [todosTabBarHandler installOnTabBarButtonView:buttonView];
}

@end
