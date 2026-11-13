#import <UIKit/UIKit.h>

/// Full-screen WKWebView hosting the bundled Lists page (lists.html). The page owns all UI and
/// logic; this controller is only the bridge: the API token and the state file shared with the widget.
@interface ListsViewController : UIViewController

/// lists://list/<id>: show that list. Queued until the page has loaded on a cold launch.
- (void)openListWithId:(NSString *)listId;
/// The app came back to the foreground: the page re-syncs.
- (void)appDidForeground;

@end
