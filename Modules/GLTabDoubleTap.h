#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Decides whether a tab bar tap completes a double-tap. Fed every
// UITabBarControllerDelegate -didSelectViewController: call (which fires on
// re-taps of the selected tab too), so a first tap that switches to a tab
// and a second tap that re-taps it count as one double-tap. Pure Foundation
// so SharedTests can drive tap timings directly.
//
// Two taps on the SAME target within `window` seconds fire once; the state
// then resets so a third rapid tap starts a new pair instead of firing again
// (same rule as TodosModule's double-tap).
@interface GLTabDoubleTap : NSObject

- (instancetype)initWithWindow:(NSTimeInterval)window NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Records a tap on `target` at `time` (seconds, any monotonic clock).
/// Returns YES when this tap completes a double-tap.
- (BOOL)registerTapOn:(id)target atTime:(NSTimeInterval)time;

@end

NS_ASSUME_NONNULL_END
