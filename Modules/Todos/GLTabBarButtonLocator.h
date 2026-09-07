#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Finds a UITabBar's per-item button view without depending on the private
// UITabBarButton class name. See GLTabBarButtonLocator.m for why a
// one-level `tabBar.subviews` walk (the old approach) stopped working on
// iOS 26.
@interface GLTabBarButtonLocator : NSObject

+ (nullable UIView *)buttonViewInTabBar:(UITabBar *)tabBar atItemIndex:(NSUInteger)itemIndex;

@end

NS_ASSUME_NONNULL_END
