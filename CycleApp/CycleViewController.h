#import <UIKit/UIKit.h>

@class CycleBridge;

/// Full-screen WKWebView hosting the bundled page (web/index.html). The page owns all UI and
/// logic; this controller only wires the web view to the `cycle` bridge.
@interface CycleViewController : UIViewController
- (instancetype)initWithBridge:(CycleBridge *)bridge;
@end
