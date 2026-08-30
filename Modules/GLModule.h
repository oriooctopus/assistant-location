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
/// first-launch auto-enable, migrations). `launchOptions` is passed through
/// unmodified from UIKit — a module that cares about a specific key (e.g.
/// `UIApplicationLaunchOptionsLocationKey`) inspects it itself; the shell
/// attaches no meaning to any key in this dictionary.
+ (void)moduleDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions;

/// Called for `scene:openURLContexts:` (custom-scheme deep links, e.g.
/// `overland://...`). Return YES once a module has fully handled the URL;
/// GLModuleRegistry stops routing at the first YES and returns NO if no
/// module claims it.
+ (BOOL)moduleHandleURL:(NSURL *)url;

/// Called for `application:continueUserActivity:restorationHandler:` (Siri
/// shortcuts / Handoff). The activity is passed through unmodified — a
/// module checks `activity.activityType` itself. Return YES once a module
/// has fully handled the activity; GLModuleRegistry stops at the first YES
/// and returns NO if no module claims it. A module MUST return NO for
/// activity types it does not own so the registry can offer the activity to
/// the next module.
+ (BOOL)moduleHandleUserActivity:(NSUserActivity *)activity;

/// Called for home-screen quick actions (UIApplicationShortcutItem), from
/// both a warm-launch `windowScene:performActionForShortcutItem:` and a cold
/// launch's `connectionOptions.shortcutItem`. Return YES once a module has
/// handled the item; GLModuleRegistry stops at the first YES. A module MUST
/// return NO for item types it does not own so the registry can offer the
/// item to the next module.
+ (BOOL)moduleHandleShortcutItem:(UIApplicationShortcutItem *)item;

/// One or more `\n`-joined lines of diagnostic text (e.g. "endpoint: ...")
/// for the shell's first-launch build diagnostic alert, or nil/empty if this
/// module has nothing to contribute. GLModuleRegistry joins every module's
/// non-empty summary with "\n" beneath the shell's own build-stamp lines.
+ (NSString *)moduleDiagnosticSummary;

/// Called when the app enters the background (mirrors
/// UISceneDidEnterBackgroundNotification). Existing modules that need this
/// today (e.g. TrackerAppLifecycle) hand-roll their own `+load` notification
/// observer instead of using the contract — this hook exists so a future
/// module doesn't have to copy that pattern. GLModuleRegistry observes the
/// underlying UIScene notification exactly once and fans out to every
/// conforming module, in +moduleOrder-then-class-name order.
+ (void)moduleDidEnterBackground;

/// Called when the app is about to enter the foreground (mirrors
/// UISceneWillEnterForegroundNotification). See -moduleDidEnterBackground.
+ (void)moduleWillEnterForeground;

/// Called when the app is about to resign active (mirrors
/// UISceneWillDeactivateNotification). See -moduleDidEnterBackground.
+ (void)moduleWillResignActive;

/// Return YES to make this the tab the app opens on: both a cold launch and
/// a resume from the background after a long-enough absence (see
/// SceneDelegate's resume threshold). GLModuleRegistry walks +moduleClasses
/// in +moduleOrder-then-class-name order and selects the FIRST module that
/// returns YES here — at most one module should implement this returning
/// YES, since a second YES is simply never reached.
+ (BOOL)moduleIsDefaultTab;

@end
