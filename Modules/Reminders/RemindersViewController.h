// The Reminders tab: a WKWebView pointing at the reminders web app running
// on the desktop box, port 8312 — see MODULES.md / repo port registry.
//
// Thin subclass of GLWebModuleViewController (Shared/) — the base class owns
// the WKWebView setup, pull-to-refresh, error+retry view and theme
// propagation; this file supplies only the URL and display name.

#import "GLWebModuleViewController.h"

@interface RemindersViewController : GLWebModuleViewController
@end
