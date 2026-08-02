// The Events tab: a WKWebView pointing at the event-finder swipe app running
// on the desktop box (events/server.py, port 8304 — see MODULES.md / repo
// port registry). The web app is a full swipe UI (card deck, filters,
// location profiles) that changes daily; hosting it in a webview avoids
// duplicating that logic natively and re-porting it every time it drifts.

#import <UIKit/UIKit.h>

@interface EventsViewController : UIViewController
@end
