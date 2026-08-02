// The micro-app contract.
//
// A "module" is one tab in the app. Anything conforming to this protocol is
// discovered by GLModuleRegistry at launch and installed as a tab — there is
// no registry list, no storyboard entry and no project.pbxproj entry to edit,
// which is what lets several sessions add tabs at the same time without
// touching a shared file. See MODULES.md at the repo root.
//
// Every method is a CLASS method: the registry never instantiates the module
// class itself, it only asks it for a view controller.

#import <UIKit/UIKit.h>

@protocol GLModule <NSObject>

/// Tab bar item title. Also set as the view controller's `title`.
+ (NSString *)moduleTitle;

/// Tab bar item image. Return an SF Symbol, e.g.
/// `[UIImage systemImageNamed:@"calendar"]`.
+ (UIImage *)moduleIcon;

/// Left-to-right position in the tab bar; lower sorts first. Existing modules
/// use 100 (Tracker), 200 (Settings), 300 (Upload) — leave gaps and pick an
/// unused value. Ties break on class name so the bar is always deterministic.
+ (NSInteger)moduleOrder;

/// A fresh root view controller for this tab. Called exactly once per launch.
/// The registry sets `title`, `tabBarItem` and `restorationIdentifier` on the
/// result, so a module never has to.
+ (UIViewController *)makeViewController;

@end
