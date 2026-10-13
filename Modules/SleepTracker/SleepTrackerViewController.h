// The "Sleep" tab: a WKWebView pointing at the sleep-tracker web app running on
// the desktop box, port 8325 (plain HTTP over the tailnet). Thin subclass of
// GLWebModuleViewController (Shared/), which owns the WKWebView setup,
// pull-to-refresh, error+retry view, offline shell and theme propagation.

#import "GLWebModuleViewController.h"

@interface SleepTrackerViewController : GLWebModuleViewController
@end
