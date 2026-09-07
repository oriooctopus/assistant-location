#import "GLTabBarButtonLocator.h"

@implementation GLTabBarButtonLocator

// Recursively collects the OUTERMOST UIControl descendants of `view`: if a
// subview is itself a UIControl, it's collected and NOT recursed into (a
// tab bar button's own internal image/label views are UIControl's private
// implementation detail, not separate buttons); otherwise the walk
// continues into that subview's own subviews. Hidden views and zero-size
// frames are skipped -- neither is a real, tappable button.
//
// This works on both the pre-iOS-26 flat layout (the per-item buttons are
// direct children of UITabBar, i.e. found at depth 1) and the iOS 26
// "Liquid Glass" layout (the buttons are nested inside an intermediate
// container view, found at depth 2+), without depending on the private
// UITabBarButton class name, which is exactly what a plain one-level
// `tabBar.subviews` filter (the old approach) got wrong on iOS 26 -- the
// per-item controls are no longer direct children of the bar, so that walk
// silently found zero UIControls.
static void GLCollectOutermostControls(UIView *view, NSMutableArray<UIControl *> *outControls) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || CGSizeEqualToSize(subview.frame.size, CGSizeZero)) {
            continue;
        }
        if ([subview isKindOfClass:[UIControl class]]) {
            [outControls addObject:(UIControl *)subview];
            continue;
        }
        GLCollectOutermostControls(subview, outControls);
    }
}

+ (nullable UIView *)buttonViewInTabBar:(UITabBar *)tabBar atItemIndex:(NSUInteger)itemIndex {
    NSMutableArray<UIControl *> *controls = [NSMutableArray array];
    GLCollectOutermostControls(tabBar, controls);

    NSArray<UIControl *> *sorted = [controls sortedArrayUsingComparator:^NSComparisonResult(UIControl *a, UIControl *b) {
        CGFloat ax = [a.superview convertPoint:a.frame.origin toView:tabBar].x;
        CGFloat bx = [b.superview convertPoint:b.frame.origin toView:tabBar].x;
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    if (itemIndex >= sorted.count) return nil;
    return sorted[itemIndex];
}

@end
