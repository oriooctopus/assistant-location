// The Esme tab: a WKWebView pointing at the relationship check-in web app
// running on the desktop box (port 8323 — built by a separate backend team,
// see EsmeModule.h). Hosting it in a webview avoids duplicating that app
// natively, same as Finances.
//
// Thin subclass of GLWebModuleViewController (Shared/) — the base class owns
// the WKWebView setup, pull-to-refresh, error+retry view and theme
// propagation; this file supplies the URL/display name plus the
// tap-the-daily-notification -> open-the-check-in-flow handoff (see
// EsmeModule.m's notification delegate).

#import "GLWebModuleViewController.h"

@interface EsmeViewController : GLWebModuleViewController
@end
