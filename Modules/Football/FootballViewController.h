// The Football tab: a WKWebView pointing at the SAME event-finder app the
// Events tab uses (events/server.py, port 8304), but with ?tab=football
// appended — that param PINS the app to its football fixtures view for the
// life of this window (no Events/Football switch inside the page; the two
// tabs of THIS app are what let you get back and forth). See the events
// repo's events/web/index.html for the pinning contract.
//
// Thin subclass of GLWebModuleViewController (Shared/) — the base class owns
// the WKWebView setup, pull-to-refresh, error+retry view and theme
// propagation; this file supplies only the URL and display name.

#import "GLWebModuleViewController.h"

@interface FootballViewController : GLWebModuleViewController
@end
