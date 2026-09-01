// Runtime discovery of GLModule conformers. See GLModule.h and MODULES.md.

#import <UIKit/UIKit.h>
#import "GLModule.h"

@interface GLModuleRegistry : NSObject

/// Every registered module class (see +registerModule:), sorted by
/// +moduleOrder then class name.
/// Untyped NSArray on purpose: `NSArray<Class>` parses as a protocol qualifier.
+ (NSArray *)moduleClasses;

/// Called from each module class's own `+load`, once per module, to register
/// it with the registry. Do not call this from anywhere except a module's
/// `+load` — see GLModuleRegistry.m for why load-time self-registration
/// replaced runtime scanning, and MODULES.md for the resulting contract.
+ (void)registerModule:(Class)module;

/// One configured view controller per module, in tab order.
+ (NSArray<UIViewController *> *)makeViewControllers;

/// Replaces `tabs.viewControllers` with the discovered modules and logs the
/// resulting tab bar (CI asserts on that line).
+ (void)installIntoTabBarController:(UITabBarController *)tabs;

/// Test hook: opens the More-overflow module carrying this restoration
/// identifier (e.g. "GLModule.AutoJournalModule") — a thin wrapper over
/// +openOverflowModuleWithIdentifier: below, kept under this name for
/// SceneDelegate's UITEST_MORE_TILE environment hook and sim-test.yml's
/// tile loop, both written against it. Returns NO if there is no such
/// module, or if the More screen was never installed (four modules or
/// fewer).
+ (BOOL)openMoreTileWithIdentifier:(NSString *)identifier;

/// Test hook: taps the More-grid tile carrying this restoration identifier
/// THROUGH THE WEB PAGE ITSELF — evaluates JS in more.html's own WKWebView to
/// dispatch a real `click` DOM event on the matching `.gl-tile[data-id=...]`
/// element, running the exact page -> GLBridge.call('openModule') ->
/// GLWebBridge -> +openOverflowModuleWithIdentifier: chain a finger tap
/// would, unlike +openMoreTileWithIdentifier: above (which calls into native
/// module code directly and never exercises the bridge). `completionHandler`
/// is called on the main queue with NO if the More screen isn't installed,
/// its page hasn't loaded far enough to have rendered the tile, or no tile
/// with that identifier exists in the DOM.
+ (void)tapMoreGridTileWithIdentifier:(NSString *)identifier
                      completionHandler:(void (^)(BOOL tapped))completionHandler;

/// Test hook: evaluates JS in the More screen's own WKWebView to read back
/// `Object.keys(window.GL_BOOT.palette || {})`, sorted, and NSLogs them as
/// `UITEST_PALETTE_KEYS: <comma-separated keys>` -- so a test that injects a
/// palette (SIMCTL_CHILD_UITEST_NATIVE_PALETTE, see GLTheme's
/// +currentPaletteColors) can assert the PAGE actually received those exact
/// keys, not just that the env var was set. This is the guard sim-test.yml
/// never had: the harness could inject a palette missing a key (it did --
/// see design-tokens/native-theme.json's surface-translucent/backdrop-blur)
/// and every screenshot still looked like a plausible, silently-wrong
/// render. Logs `UITEST_PALETTE_KEYS: (more screen not installed)` if the
/// More screen was never installed (four modules or fewer), or if the JS
/// eval itself failed, logs the error instead of a key list -- either way
/// the caller greps for a specific key by name, so a missing line is
/// exactly as loud as a line missing that key.
+ (void)logPaletteKeysReceivedByMoreScreen;

/// Descriptors (`{identifier, title}`, both NSString) for every module
/// currently in the More overflow, in module order — empty when there is no
/// overflow (four modules or fewer). Backs the More web page's `listModules`
/// bridge method (Modules/WebBridge/GLWebBridge.m) with the exact same list
/// +openOverflowModuleWithIdentifier: below searches.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)overflowModuleDescriptors;

/// Opens the overflow module with this restoration identifier, running the
/// exact select-vs-push logic a tile tap used to run directly on
/// GLMoreGridViewController (see GLModuleRegistry.m) — now shared by
/// GLWebBridge's `openModule` handler AND +openMoreTileWithIdentifier:
/// above, which is just a thin wrapper over this so SceneDelegate's
/// UITEST_MORE_TILE hook and sim-test.yml's tile loop keep working
/// unchanged. Returns NO if there is no such module, or if the More screen
/// was never installed.
+ (BOOL)openOverflowModuleWithIdentifier:(NSString *)identifier;

#pragma mark - Optional-hook fan-out

/// Calls `+moduleDidFinishLaunchingWithOptions:` on every conforming module
/// that implements it, in module order, passing `launchOptions` through
/// unmodified. Logs which modules responded, in the same style as the
/// installed-tabs log line (CI asserts on it). See GLModule.h.
+ (void)notifyModulesDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions;

/// Offers `url` to `+moduleHandleURL:` on each module in order; stops and
/// returns YES at the first module that returns YES. Returns NO if no
/// module claims the URL.
+ (BOOL)routeURL:(NSURL *)url;

/// Offers `activity` to `+moduleHandleUserActivity:` on each module in
/// order; stops and returns YES at the first module that returns YES.
/// Returns NO if no module claims the activity.
+ (BOOL)routeUserActivity:(NSUserActivity *)activity;

/// Offers `item` to `+moduleHandleShortcutItem:` on each module in order;
/// stops and returns YES at the first module that returns YES. Returns NO
/// if no module claims the item.
+ (BOOL)routeShortcutItem:(UIApplicationShortcutItem *)item;

/// Joins every module's non-empty `+moduleDiagnosticSummary` with "\n", in
/// module order.
+ (NSString *)diagnosticSummary;

#pragma mark - Default tab

/// Selects the tab bar's default tab: the first module (in
/// +moduleOrder-then-class-name order) whose `+moduleIsDefaultTab` returns
/// YES, mapped to its matching index in `tabs.viewControllers` — module
/// index N is view-controller index N, since +makeViewControllers builds one
/// controller per module in that same order. Sets `tabs.selectedIndex` and
/// logs the selection. Returns NO, logging nothing, if no module opts in.
/// Called from SceneDelegate on cold launch and on a foreground resume past
/// the resume threshold — see SceneDelegate.m.
+ (BOOL)selectDefaultTabInTabBarController:(UITabBarController *)tabs;

#pragma mark - App-lifecycle fan-out

/// Registers observers (once, via dispatch_once) for
/// UISceneDidEnterBackgroundNotification / UISceneWillEnterForegroundNotification /
/// UISceneWillDeactivateNotification and fans each out to every conforming
/// module's +moduleDidEnterBackground / +moduleWillEnterForeground /
/// +moduleWillResignActive, guarded by respondsToSelector:. Call once at
/// launch (idempotent — a second call is a no-op).
+ (void)startObservingAppLifecycle;

@end
