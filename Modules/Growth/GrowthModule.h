// Growth micro app: hosts the self-growth review web app in a WKWebView.

#import <Foundation/Foundation.h>
#import "GLModule.h"

NS_ASSUME_NONNULL_BEGIN

@interface GrowthModule : NSObject <GLModule>

/// Records that a Growth review gesture just completed, starting (or
/// extending, never shortening) this module's "quiet window" -- see
/// GLGrowthQuietWindow. `quietSeconds` is how long Growth stays out of the
/// default-tab pick; nil means the 30-minute default (a card answer), and a
/// tile pick passes 4 hours. Called by GLWebBridge in response to the web
/// page's `growthReviewed` bridge call -- exposed as a class method here
/// (rather than folding the NSUserDefaults write into the bridge itself) so
/// the bridge doesn't need to know GrowthModule's storage, matching how
/// GLWebBridge already defers to other modules' own class methods (e.g.
/// GLModuleRegistry's +showModuleWithIdentifier:).
+ (void)noteReviewCompletedWithQuietSeconds:(nullable NSNumber *)quietSeconds;

/// YES if a review gesture was recorded (see +noteReviewCompletedWithQuietSeconds:)
/// and its quiet window has not yet ended. Exposed mainly so a test can
/// assert the quiet-window
/// math directly without also exercising +moduleIsDefaultTab's YES/NO
/// mapping.
+ (BOOL)isWithinQuietWindow;

@end

NS_ASSUME_NONNULL_END
