// Regression test for the iOS 26 ("Liquid Glass") UITabBarController
// rewrite: a real UITabBar's per-item button views are no longer direct
// children of the bar (see GLTabBarButtonLocator.m's header comment), so a
// one-level `tabBar.subviews` filter -- the old approach -- silently finds
// none of them. This test drives an ACTUAL UITabBarController through real
// UIKit layout (a bare, hand-built view hierarchy would not reproduce the
// bug, since it never runs UIKit's own private button-hierarchy code) and
// asserts +buttonViewInTabBar:atItemIndex: still finds all four buttons.
#import <XCTest/XCTest.h>
#import "GLTabBarButtonLocator.h"

// Logs `view`'s whole descendant tree (class, depth, frame) and collects the
// outermost UIControls the same way GLTabBarButtonLocator does, so the CI log
// carries the actual iOS-26 tab bar shape rather than our assumption of it.
static void GLDumpViewTree(UIView *view, NSUInteger depth, NSMutableArray<UIControl *> *outControls) {
    for (UIView *subview in view.subviews) {
        NSLog(@"TAB BAR TREE: %*s%@ frame=%@ hidden=%d",
              (int)(depth * 2), "", NSStringFromClass([subview class]),
              NSStringFromCGRect(subview.frame), subview.hidden);
        if ([subview isKindOfClass:[UIControl class]] && !subview.hidden &&
            !CGSizeEqualToSize(subview.frame.size, CGSizeZero)) {
            [outControls addObject:(UIControl *)subview];
            continue;
        }
        GLDumpViewTree(subview, depth + 1, outControls);
    }
}

@interface GLTabBarButtonLocatorTests : XCTestCase
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITabBarController *tabBarController;
@end

@implementation GLTabBarButtonLocatorTests

- (void)setUp {
    [super setUp];

    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    NSArray<NSString *> *titles = @[@"One", @"Two", @"Three", @"Four"];
    NSArray<NSString *> *icons = @[@"house", @"star", @"gear", @"checklist"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIViewController *vc = [[UIViewController alloc] init];
        vc.tabBarItem = [[UITabBarItem alloc] initWithTitle:titles[i]
                                                       image:[UIImage systemImageNamed:icons[i]]
                                                         tag:0];
        [controllers addObject:vc];
    }

    self.tabBarController = [[UITabBarController alloc] init];
    self.tabBarController.viewControllers = controllers;

    // A phone-sized window, made key+visible: UIKit only builds the tab
    // bar's real button-view hierarchy once it's actually part of a window
    // that's on screen -- an offscreen/non-key view can leave that
    // hierarchy unbuilt, which would make this test pass for the wrong
    // reason (nothing to find yet, rather than the locator correctly
    // finding real buttons).
    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    self.window.rootViewController = self.tabBarController;
    [self.window makeKeyAndVisible];

    [self.tabBarController.tabBar setNeedsLayout];
    [self.tabBarController.tabBar layoutIfNeeded];
}

- (void)tearDown {
    self.window.hidden = YES;
    self.window = nil;
    self.tabBarController = nil;
    [super tearDown];
}

// The assertion that fails on iOS 26 with the old one-level
// `tabBar.subviews` walk: all four items must resolve to a real, non-nil
// button view.
- (void)testFindsAButtonViewForEveryTabBarItem {
    UITabBar *tabBar = self.tabBarController.tabBar;
    for (NSUInteger i = 0; i < 4; i++) {
        UIView *button = [GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:i];
        XCTAssertNotNil(button, @"expected a button view at item index %lu", (unsigned long)i);
    }
}

- (void)testButtonViewsAreDistinctAndOrderedLeftToRight {
    UITabBar *tabBar = self.tabBarController.tabBar;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) {
        UIView *button = [GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:i];
        XCTAssertNotNil(button);
        [buttons addObject:button];
    }

    NSSet *uniqueButtons = [NSSet setWithArray:buttons];
    XCTAssertEqual(uniqueButtons.count, buttons.count, @"expected 4 distinct button view objects, got duplicates");

    CGFloat previousX = -CGFLOAT_MAX;
    for (UIView *button in buttons) {
        CGFloat x = [button.superview convertPoint:button.frame.origin toView:tabBar].x;
        XCTAssertGreaterThan(x, previousX, @"expected button views strictly ordered left-to-right by x");
        previousX = x;
    }
}

// Diagnostic + root-cause proof, not a behavioural assertion about our own
// code: reproduces the OLD lookup (a one-level `tabBar.subviews` filter to
// UIControl) against the same real, laid-out bar the tests above use, and
// dumps the bar's whole view hierarchy into the test log. On a runtime
// where the buttons are direct children this finds 4 and the old code was
// fine; on one where they are nested it finds fewer, which IS the bug the
// user hit ("nothing happens" -- the old lookup returned nil, so neither
// the double-tap nor the long-press was ever wired up). Either way the log
// records which runtime we actually ran on and what the bar really looks
// like, so a green run can't be mistaken for proof on the wrong iOS.
- (void)testDiagnoseOldOneLevelSubviewWalk {
    UITabBar *tabBar = self.tabBarController.tabBar;

    NSUInteger directControls = 0;
    for (UIView *subview in tabBar.subviews) {
        if ([subview isKindOfClass:[UIControl class]]) directControls++;
    }

    NSMutableArray<UIControl *> *nested = [NSMutableArray array];
    GLDumpViewTree(tabBar, 0, nested);

    // The locator's resolved group count: on iOS 26 `nested.count` can be a
    // multiple of `tabBar.items.count` (measured 8 for 4 items -- each
    // button rendered twice, in parallel SelectedContentView/ContentView
    // layers), so the raw recursive-control count is no longer the number
    // we expect to equal items.count. What must still equal items.count is
    // how many distinct, resolvable buttons the LOCATOR produces.
    NSUInteger resolvedCount = 0;
    while ([GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:resolvedCount] != nil) {
        resolvedCount++;
    }

    NSLog(@"TAB BAR DIAGNOSTIC: iOS %@ -- old one-level walk found %lu UIControl "
          @"direct subviews; recursive walk found %lu outermost UIControls; "
          @"locator resolved %lu groups; tabBar.items = %lu",
          UIDevice.currentDevice.systemVersion, (unsigned long)directControls,
          (unsigned long)nested.count, (unsigned long)resolvedCount,
          (unsigned long)tabBar.items.count);

    // No XCTAssert on directControls or nested.count: this test exists to
    // REPORT which raw layout this runtime uses (evidence trail for the
    // iOS-26 duplicate-layer bug), and must not go red on a runtime where
    // the raw counts differ from items.count for an unrelated reason. The
    // behavioural requirement is on the LOCATOR's resolution, not the raw
    // walk: it must produce exactly one non-nil button per real item, and
    // nil past the last one.
    for (NSUInteger i = 0; i < tabBar.items.count; i++) {
        XCTAssertNotNil([GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:i],
                        @"locator must resolve a button for every real tab bar item, index %lu", (unsigned long)i);
    }
    XCTAssertNil([GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:tabBar.items.count],
                 @"locator must return nil past the last real tab bar item");
}

// Would have caught the original bug directly: the locator could return a
// non-nil, distinct, correctly-ordered view that is still the WRONG one --
// e.g. a SelectedContentView copy that renders under the glass lens but
// never receives a touch. The other tests check shape (non-nil, distinct,
// ordered); this one checks the thing that actually matters, that tapping
// the resolved button's own centre is indistinguishable from tapping the
// real tab bar button.
- (void)testResolvedButtonIsTheOneThatActuallyReceivesTouches {
    UITabBar *tabBar = self.tabBarController.tabBar;
    for (NSUInteger i = 0; i < 4; i++) {
        UIView *button = [GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:i];
        XCTAssertNotNil(button);

        CGPoint centerInTabBar = [button.superview convertPoint:button.center toView:tabBar];
        UIView *hit = [tabBar hitTest:centerInTabBar withEvent:nil];
        XCTAssertNotNil(hit, @"expected tapping the resolved button's own centre to hit something, item %lu", (unsigned long)i);

        BOOL hitIsButtonOrDescendant = NO;
        for (UIView *walker = hit; walker != nil; walker = walker.superview) {
            if (walker == button) {
                hitIsButtonOrDescendant = YES;
                break;
            }
            if (walker == tabBar) break;
        }
        XCTAssertTrue(hitIsButtonOrDescendant,
                      @"resolved button at item %lu does not actually receive touches at its own centre", (unsigned long)i);
    }
}

- (void)testReturnsNilPastTheLastItem {
    UITabBar *tabBar = self.tabBarController.tabBar;
    UIView *button = [GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:4];
    XCTAssertNil(button, @"index 4 is past the 4 real tab bar items and must return nil");
}

@end
