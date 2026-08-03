// Base class for tabs that are thin wrappers around a locally-hosted web
// app (Events, Todos, and the future gallery tab). Collapses what were two
// 168-line near-identical clones (WKWebView setup, pull-to-refresh, the
// error view + retry, navigation-delegate methods) that differed only by
// URL, two error strings, and a comment.
//
// Theme propagation: the page is told the native appearance mode two ways —
// (1) a `?theme=light|dark` (or `&theme=...` if the URL already has a query)
// query parameter on the loaded URL, present from first paint; and (2) a
// WKUserScript injected at document start that sets
// `document.documentElement.dataset.theme` to the same value, kept in sync
// afterwards via GLThemeDidChangeNotification. Web apps should read
// `data-theme` on the root element and react to it (e.g. a MutationObserver
// or just CSS `[data-theme="dark"]` selectors) — the query param exists only
// as the first-paint fallback, since the injected script can't run before
// the page's own initial CSS does.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLWebModuleViewController : UIViewController

/// Designated initializer. `displayName` is used only in error copy (e.g.
/// "Couldn't reach <displayName> at <url>").
- (instancetype)initWithURL:(NSURL *)url displayName:(NSString *)displayName NS_DESIGNATED_INITIALIZER;

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
