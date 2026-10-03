// The Outfits tab: a WKWebView pointing at the outfits web app running on
// the desktop box, port 8314 — see MODULES.md / repo port registry.
//
// Thin subclass of GLWebModuleViewController (Shared/) — the base class owns
// the WKWebView setup, pull-to-refresh, error+retry view and theme
// propagation; this file supplies the URL and display name, plus the
// overland://outfits/<path> deep link target (-openPath:).

#import "GLWebModuleViewController.h"

@interface OutfitsViewController : GLWebModuleViewController

/// The live instance (the one tab), nil until -init has run.
+ (instancetype)current;

/// Points the page at `<base>/#/<path>`, `path` passed through verbatim (still
/// percent-encoded). Safe before the view has loaded (the first load picks the
/// fragment up) and after (navigates the loaded page; the web app sees a
/// hashchange).
- (void)openPath:(NSString *)path;
@end
