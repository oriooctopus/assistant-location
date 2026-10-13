#import <UIKit/UIKit.h>

@class GripesStore;

/// Full-screen WKWebView hosting the bundled Gripes page (gripes.html). The page owns all UI and
/// logic; this controller is only the `gl` bridge: entry storage, speech, the API token.
@interface GripesViewController : UIViewController

/// Set by the app delegate: schedules a sync after `delay` seconds (the page just wrote an entry).
@property (nonatomic, copy) void (^requestSync)(NSTimeInterval delay);

- (instancetype)initWithStore:(GripesStore *)store;
/// gripes://log: show the logging view.
- (void)openLog;
/// The store changed underneath the page (a sync pulled entries): ask the page to reload them.
- (void)entriesChanged;

@end
