// The Finances tab: a WKWebView pointing at the lm-review transaction-review
// web app running on the desktop box (port 8212, path /app — see repo port
// registry). Hosting it in a webview avoids duplicating that app natively.
//
// Thin subclass of GLWebModuleViewController (Shared/) — the base class owns
// the WKWebView setup, pull-to-refresh, error+retry view and theme
// propagation; this file supplies only the URL and display name.

#import "GLWebModuleViewController.h"

@interface FinancesViewController : GLWebModuleViewController
@end
