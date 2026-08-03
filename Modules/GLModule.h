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

// Everything below is OPTIONAL. These exist so the app shell (AppDelegate /
// SceneDelegate) can fan out app-lifecycle events to whichever module cares,
// without the shell naming that module or its headers. GLModuleRegistry
// checks `respondsToSelector:` before calling any of these — implement only
// the ones your module needs.
@optional

/// Called once from `application:didFinishLaunchingWithOptions:`, before any
/// tab is installed, in the same +moduleOrder-then-class-name order as tab
/// installation. Use for one-time launch-time setup (baked defaults,
/// first-launch auto-enable, migrations).
+ (void)moduleDidFinishLaunching;

/// Called for `scene:openURLContexts:` (custom-scheme deep links, e.g.
/// `overland://...`). Return YES once a module has fully handled the URL;
/// GLModuleRegistry stops routing at the first YES and returns NO if no
/// module claims it.
+ (BOOL)moduleHandleURL:(NSURL *)url;

/// Called for home-screen quick actions (UIApplicationShortcutItem), from
/// both a warm-launch `windowScene:performActionForShortcutItem:` and a cold
/// launch's `connectionOptions.shortcutItem`. Return YES once a module has
/// handled the item; GLModuleRegistry stops at the first YES.
+ (BOOL)moduleHandleShortcutItem:(UIApplicationShortcutItem *)item;

/// One or more `\n`-joined lines of diagnostic text (e.g. "endpoint: ...")
/// for the shell's first-launch build diagnostic alert, or nil/empty if this
/// module has nothing to contribute. GLModuleRegistry joins every module's
/// non-empty summary with "\n" beneath the shell's own build-stamp lines.
+ (NSString *)moduleDiagnosticSummary;

@end
