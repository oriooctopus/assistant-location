// Growth micro app: hosts the self-growth review web app in a WKWebView.

#import <Foundation/Foundation.h>
#import "GLModule.h"

@interface GrowthModule : NSObject <GLModule>

/// Records that a Growth review gesture just completed, starting this
/// module's 2-hour "quiet window" (see +moduleIsDefaultTab / GrowthModule.m).
/// Called by GLWebBridge in response to the web page's `growthReviewed`
/// bridge call -- exposed as a class method here (rather than folding the
/// NSUserDefaults write into the bridge itself) so the bridge doesn't need
/// to know GrowthModule's storage key, matching how GLWebBridge already
/// defers to other modules' own class methods (e.g. GLModuleRegistry's
/// +selectTabWithIdentifier:fromViewController:) instead of reaching into
/// their internals.
+ (void)noteReviewCompleted;

/// YES if a review gesture was recorded (see +noteReviewCompleted) within
/// the last 2 hours. Exposed mainly so a test can assert the quiet-window
/// math directly without also exercising +moduleIsDefaultTab's YES/NO
/// mapping.
+ (BOOL)isWithinQuietWindow;

@end
