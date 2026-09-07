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

    NSLog(@"TAB BAR DIAGNOSTIC: iOS %@ -- old one-level walk found %lu UIControl "
          @"direct subviews; recursive walk found %lu outermost UIControls; "
          @"tabBar.items = %lu",
          UIDevice.currentDevice.systemVersion, (unsigned long)directControls,
          (unsigned long)nested.count, (unsigned long)tabBar.items.count);

    // No XCTAssert on directControls: this test exists to REPORT which
    // layout this runtime uses, and must not go red on a runtime where the
    // old approach happened to work.
    XCTAssertEqual(nested.count, tabBar.items.count,
                   @"recursive walk must find exactly one outermost control per tab bar item");
}

- (void)testReturnsNilPastTheLastItem {
    UITabBar *tabBar = self.tabBarController.tabBar;
    UIView *button = [GLTabBarButtonLocator buttonViewInTabBar:tabBar atItemIndex:4];
    XCTAssertNil(button, @"index 4 is past the 4 real tab bar items and must return nil");
}

@end
