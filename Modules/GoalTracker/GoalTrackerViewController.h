// The "Continue?" tab: a WKWebView pointing at the goal-tracker web app
// running on the desktop box, port 8316 (plain HTTP over the tailnet; the app
// Info.plist allows arbitrary loads). Thin subclass of
// GLWebModuleViewController (Shared/), which owns the WKWebView setup,
// pull-to-refresh, error+retry view and theme propagation.

#import "GLWebModuleViewController.h"

@interface GoalTrackerViewController : GLWebModuleViewController
@end
