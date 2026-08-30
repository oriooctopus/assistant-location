// Base class for tabs that are thin wrappers around a web app — either a
// locally-hosted server (Events, Todos, Journal's Recent-recordings page) or
// a page bundled straight into the app (Settings, the More screen). Collapses
// what were two 168-line near-identical clones (WKWebView setup,
// pull-to-refresh, the error view + retry, navigation-delegate methods) that
// differed only by URL, two error strings, and a comment.
//
// Theme propagation, two mechanisms that now coexist:
// (1) the legacy `?theme=light|dark` query parameter (HTTP pages only — see
//     -themedWebURL) plus a WKUserScript setting
//     `document.documentElement.dataset.theme`, both present from first
//     paint, kept in sync afterwards via GLThemeDidChangeNotification; and
// (2) the frozen native<->web bridge protocol's boot injection
//     (`window.GL_BOOT = {palette, mode, themeId, platform}` — see
//     -bootScriptSource) plus live `window.__glThemeChanged(state)` pushes
//     on GLThemeDidChangeNotification/GLPaletteDidChangeNotification,
//     rebuilt on EVERY -loadPage rather than once at -viewDidLoad so a
//     mode/palette change picked up between loads is never stale. Every
//     page also gets a GLWebBridge attached under WKUserContentController
//     name "gl" (see Modules/WebBridge/GLWebBridge.h for the full protocol);
//     a page that never calls into it just never triggers it.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLWebModuleViewController : UIViewController

/// Designated initializer, for a page hosted over HTTP(S). `displayName` is
/// used only in error copy (e.g. "Couldn't reach <displayName> at <url>").
- (instancetype)initWithURL:(NSURL *)url displayName:(NSString *)displayName NS_DESIGNATED_INITIALIZER;

/// For a page bundled directly into the app (e.g. "settings.html",
/// "more.html" — see Modules/WebPages/). Loads via
/// `loadFileURL:allowingReadAccessToURL:`, granting read access to the
/// resource's containing directory so sibling resources (gl-bridge.js,
/// page.css) load too. Raises `NSInternalInconsistencyException`
/// immediately if `pageName` isn't found in the bundle — this is the fastest
/// way to discover that Modules/'s file-system-synchronized group isn't
/// copying .html resources into the build product, rather than failing
/// silently into the generic network-error view.
- (instancetype)initWithBundledPageNamed:(NSString *)pageName;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// The URL to load. Default implementation returns the value passed to
/// -initWithURL:displayName:. A subclass instantiated via plain -init must
/// override this instead.
- (NSURL *)webURL;

/// Used only in error copy. Default implementation returns the value passed
/// to -initWithURL:displayName:. A subclass instantiated via plain -init
/// must override this instead.
- (NSString *)displayName;

@end

NS_ASSUME_NONNULL_END
