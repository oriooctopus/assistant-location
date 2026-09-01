// The native side of the GL native<->web bridge protocol v1 -- the WKWebView
// message handler shared by every GLWebModuleViewController-hosted page
// (bundled or HTTP), attached under WKUserContentController name "gl". This
// header is the frozen protocol contract; the pages under Modules/WebPages/
// (settings.html, more.html, and gl-bridge.js's client-side wrapper) were
// written against this exact wire shape and must not change independently of
// it.
//
// Page -> native: `window.webkit.messageHandlers.gl.postMessage({id, method,
// params})` -- `id` a string, `params` a plain object.
//
// Native -> page: `window.__glReply(id, result, error)` -- `result` an
// object or null, `error` a string or null. GLWebBridge replies EXACTLY ONCE
// per request, on the main queue, for every method below (see
// GLWebBridge.m's -userContentController:didReceiveScriptMessage: for the
// per-branch proof).
//
// Boot injection (a WKUserScript, document-start, rebuilt on every page
// load by GLWebModuleViewController -- see -installBootUserScript there,
// NOT this file):
//
//     window.GL_BOOT = {palette: <object|null>, mode: "light"|"dark",
//                        themeId: <string|null>, platform: "ios"};
//     document.documentElement.dataset.theme = <same mode>;
//
// `palette` is the current native palette leaf (+[GLTheme
// currentPaletteColors]): keys "bg", "surface", "text", "text-dim", "accent",
// "danger" (hex strings) plus an optional "bg-gradient", and an optional
// "surface-translucent"/"backdrop-blur" pair (color.surface's true
// alpha-preserving "rgba(...)" value + fx.backdrop-blur's raw CSS value,
// present only for themes that opt into glass tiles -- see design-tokens/
// build.mjs's NATIVE_COLOR_KEYS comment block), exactly as cached by
// GLTheme; null when no palette is cached yet (first-ever launch, offline).
//
// Theme push into a LIVE page (no reload), from GLWebModuleViewController on
// GLThemeDidChangeNotification / GLPaletteDidChangeNotification:
//
//     window.__glThemeChanged({palette, mode, themeId})
//
// via evaluateJavaScript, sent only if the page defines it (guarded with
// `typeof window.__glThemeChanged === 'function' &&`).
//
// Methods (all dispatched through -userContentController:didReceiveScriptMessage:):
//
// - `listModules` -> `{modules: [{identifier, title}]}` -- overflow modules
//   only (those past the first 4 by +moduleOrder), in module order.
//   `identifier` is the GLModule registry identifier (e.g.
//   "GLModule.AutoJournalModule"), `title` is the module's display title.
//
// - `openModule {identifier}` -> `{opened: bool}` -- replicates
//   GLMoreGridViewController's former -openModuleViewController: logic (now
//   GLModuleRegistry's +openModuleViewController:ontoNavigationController:):
//   a module wrapped in a UINavigationController (Journal) is SELECTED,
//   never pushed -- pushing a nav controller raises
//   NSInvalidArgumentException.
//
// - `goBack {}` -> `{}` -- pops the containing navigation controller.
//
// - `getMode` -> `{mode: 0|1|2}`; `setMode {mode}` -> `{}` (calls
//   +[GLTheme setCurrentMode:]).
//
// - `getThemeState` -> `{selectedId: string|null, themes: array|null,
//   error: string|null}` -- native performs GET
//   http://GL_BAKED_HOST:8304/themes.json and GET /api/theme (see
//   SettingsViewController.m for the reference implementation of these same
//   requests/response shapes); `themes` is passed through verbatim. Unbaked
//   host or network failure -> `themes` null + `error` a string, all inside
//   the RESULT object (the bridge-level reply error stays nil -- the RPC
//   itself succeeded, it's the reported state that's unavailable).
//
// - `setTheme {id: string|null}` -> `{ok: bool, error: string|null}` --
//   native PUT /api/theme (same body shape as SettingsViewController.m) then
//   +[GLTheme refreshPaletteFromServer] on success. Same error-placement rule
//   as `getThemeState`: `error` lives inside the result, not the bridge reply.
//
// - `locationPermission` -> `{status: "always"|"whenInUse"|"denied"|
//   "restricted"|"notDetermined"}` (from GLManager's
//   locationManager.authorizationStatus).
//
// - `requestLocationPermission` -> `{}` -- if status is notDetermined, calls
//   +[[GLManager sharedManager] requestAuthorizationPermission]; if
//   denied/restricted, opens UIApplicationOpenSettingsURLString (iOS won't
//   re-prompt).
//
// - `configureWifiZone` -> `{}` -- presents the wifi-zone screen MODALLY
//   (its Save/Reset call dismissViewControllerAnimated:; a push would strand
//   it). Instantiated from Location.storyboard's "WifiZoneViewController"
//   scene (storyboardIdentifier added for exactly this).
//
// - `getApiToken` -> `{token: string}` -- GL_BAKED_TOKEN. Gated: replies with
//   the token only when the REQUESTING FRAME's URL is file:// or its host
//   equals GL_BAKED_HOST; otherwise a bridge-level error reply, never the
//   token.
//
// - `getPref {key}` -> `{value: <json|null>}`; `setPref {key, value}` ->
//   `{}` -- whitelist ONLY: "moreOrder" <-> GLMoreGridOrderDefaultsName,
//   "moreHeroes" <-> GLMoreGridHeroesDefaultsName, "cleanTranscripts" <->
//   GLJournalCleanedTranscriptsDefaultsName (RecentRecordingsViewController.h).
//   An unknown key is a bridge-level error reply, never silent success.
//
// - Any other method name -> bridge-level error reply
//   "unknown method <name>".

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLWebBridge : NSObject <WKScriptMessageHandler>

/// `hostViewController` is the GLWebModuleViewController this bridge is
/// attached to -- used for `goBack` (pops its navigationController) and
/// `configureWifiZone` (presents modally from it). Held weakly: the
/// WKUserContentController holds a STRONG reference to this bridge, so a
/// strong back-reference here would be a retain cycle.
- (instancetype)initWithHostViewController:(UIViewController *)hostViewController;

@end

NS_ASSUME_NONNULL_END
