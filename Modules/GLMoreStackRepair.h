#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The stack GLMoreStackCoordinator's -installRootIfNeeded hands to
// -setViewControllers: so `root` (the web More page) sits at index 0
// exactly once. Pure Foundation so SharedTests can drive every stack shape
// UIKit produces without a running tab bar controller.
//
// UIKit resets the More stack by putting its own list controller at index 0
// whenever an overflow tab is selected (Journal's openModule does this), and
// sometimes leaves our root in the stack above it: [list, root, Journal].
// Overwriting index 0 alone then yields [root, root, Journal], and UIKit
// raises "All view controllers in a navigation controller must be distinct"
// -- the crash on opening Journal after saving an entry (crash reports of
// 2026-10-12). So every other occurrence of root is dropped first.
NSArray *GLMoreStackWithRoot(NSArray *stack, id root);

NS_ASSUME_NONNULL_END
