// The Todos tab: a WKWebView pointing at the todo-sorter web app running on
// the desktop box (port 8308 — see MODULES.md / repo port registry). Hosting
// it in a webview avoids duplicating that logic natively and re-porting it
// every time it drifts.
//
// Thin subclass of GLWebModuleViewController (Shared/) — the base class owns
// the WKWebView setup, pull-to-refresh, error+retry view and theme
// propagation; this file supplies only the URL and display name.

#import "GLWebModuleViewController.h"

@interface TodosViewController : GLWebModuleViewController
@end
