#import "GLTabBarButtonLocator.h"
#import <math.h> // fabs, for the slot centre-x tolerance comparison below

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

// A real iOS 26.2 4-item UITabBar's recursive control walk does NOT return
// 4 controls -- it returns 8, because Liquid Glass renders each tab button
// TWICE in parallel sibling layers (measured on a real simulator run,
// 34154095451):
//
//   _UITabBarPlatterView
//     ..SelectedContentView         <- 4 _UITabButtons, used under the glass lens
//       _UITabButton {{4,4},{95,54}}
//       _UITabButton {{85.666,4},{95,54}}
//       _UITabButton {{167.333,4},{95,54}}
//       _UITabButton {{249,4},{95,54}}
//     _UILiquidLensView              <- glass/portal decoration, no controls
//     ..ContentView                  <- 4 MORE _UITabButtons, same x positions,
//       _UITabButton {{4,4},{95,54}}    LATER in subview order so on TOP in
//       _UITabButton {{85.666,4},{95,54}}  z-order -> this is the layer that
//       _UITabButton {{167.333,4},{95,54}} actually receives touches
//       _UITabButton {{249,4},{95,54}}
//
// So the 8 controls form 4 horizontal slots of 2 duplicates each, and the
// old code (index straight into a flat sorted array of all controls) was
// off by a factor of 2: index 1 returned a slot-0 duplicate, index 4 wrongly
// returned a real button instead of nil, etc.
//
// Rather than hard-code any assumption about which private layer
// (SelectedContentView vs ContentView vs _UILiquidLensView) is "the real
// one" -- that's an iOS-26-specific implementation detail Apple can reshuffle
// at any point -- this locator groups controls into horizontal slots by
// centre-x, then asks UIKit itself which member of a slot's group is
// interactive: `-[UITabBar hitTest:withEvent:]` is the authoritative answer
// to "which view would receive a touch here", which is exactly the question
// a caller of this locator needs answered.
static const CGFloat kGLSlotTolerance = 1.0;

+ (nullable UIView *)buttonViewInTabBar:(UITabBar *)tabBar atItemIndex:(NSUInteger)itemIndex {
    NSMutableArray<UIControl *> *controls = [NSMutableArray array];
    GLCollectOutermostControls(tabBar, controls);

    // Convert every control's frame into tabBar's own coordinate space up
    // front -- slot grouping and hit-testing both need to compare/act in
    // that single shared space, not each control's own superview's space.
    NSMutableArray<NSValue *> *framesInTabBar = [NSMutableArray arrayWithCapacity:controls.count];
    for (UIControl *control in controls) {
        CGRect frame = [control.superview convertRect:control.frame toView:tabBar];
        [framesInTabBar addObject:[NSValue valueWithCGRect:frame]];
    }

    NSMutableArray<NSNumber *> *sortedIndices = [NSMutableArray arrayWithCapacity:controls.count];
    for (NSUInteger i = 0; i < controls.count; i++) {
        [sortedIndices addObject:@(i)];
    }
    [sortedIndices sortUsingComparator:^NSComparisonResult(NSNumber *aIdx, NSNumber *bIdx) {
        CGFloat ax = CGRectGetMidX(framesInTabBar[aIdx.unsignedIntegerValue].CGRectValue);
        CGFloat bx = CGRectGetMidX(framesInTabBar[bIdx.unsignedIntegerValue].CGRectValue);
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // Group controls whose centre-x lands in the same horizontal slot
    // (duplicates measured identical to floating-point noise, hence a 1pt
    // tolerance rather than exact equality). Each group is compared against
    // its own first member's centre-x, not the previous control's, so a
    // long run of near-identical values can't drift the slot boundary.
    NSMutableArray<NSMutableArray<NSNumber *> *> *slots = [NSMutableArray array];
    for (NSNumber *idx in sortedIndices) {
        CGFloat centerX = CGRectGetMidX(framesInTabBar[idx.unsignedIntegerValue].CGRectValue);
        NSMutableArray<NSNumber *> *currentSlot = slots.lastObject;
        if (currentSlot) {
            CGFloat anchorX = CGRectGetMidX(framesInTabBar[currentSlot.firstObject.unsignedIntegerValue].CGRectValue);
            if (fabs(centerX - anchorX) <= kGLSlotTolerance) {
                [currentSlot addObject:idx];
                continue;
            }
        }
        [slots addObject:[NSMutableArray arrayWithObject:idx]];
    }

    if (itemIndex >= slots.count) return nil;

    NSMutableArray<NSNumber *> *slot = slots[itemIndex];
    NSMutableSet<UIView *> *slotControls = [NSMutableSet setWithCapacity:slot.count];
    for (NSNumber *idx in slot) {
        [slotControls addObject:controls[idx.unsignedIntegerValue]];
    }

    // Ask UIKit which of this slot's duplicate controls actually receives a
    // touch, rather than guessing based on subview order or layer class.
    CGRect slotFrame = framesInTabBar[slot.firstObject.unsignedIntegerValue].CGRectValue;
    CGPoint slotCenter = CGPointMake(CGRectGetMidX(slotFrame), CGRectGetMidY(slotFrame));
    UIView *hit = [tabBar hitTest:slotCenter withEvent:nil];

    // Walk up from the hit view until we reach a member of this slot's
    // group -- the hit view itself is often an internal image/label view
    // owned by the real button, not the button itself. Stop at `tabBar`:
    // walking past it without finding a group member means hit-testing
    // didn't land on this slot at all, and we must not silently substitute
    // an arbitrary group member -- a wrong button is exactly the failure
    // this locator exists to avoid.
    UIView *walker = hit;
    while (walker != nil) {
        if ([slotControls containsObject:walker]) {
            return walker;
        }
        if (walker == tabBar) {
            break;
        }
        walker = walker.superview;
    }
    return nil;
}

@end
