#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

#import "GLKeyboardWebInset.h"

/**
 * Covers the bottom edge moving over the tab bar's strip while the keyboard is
 * up (see GLKeyboardWebInset.h for the band this closes).
 *
 * Uses a plain UIView as the hosted view rather than a WKWebView. That is not a
 * convenience: a WKWebView cannot start a web content process in a host-less
 * XCTest bundle at all (proven in GLWebKeyboardFocusTests, CI run 34182466407),
 * so a test built around the real web module could observe nothing. The
 * behaviour under test is pure Auto Layout and knows nothing about web views,
 * which is why it was split out of the view controller in the first place.
 *
 * additionalSafeAreaInsets stands in for the tab bar. A test window has no tab
 * bar and no home indicator, so without it the safe area and the container's
 * bottom coincide and every assertion below would hold trivially -- the
 * "sanity" assertion in each test exists to catch exactly that.
 */
@interface GLKeyboardWebInsetTests : XCTestCase
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIViewController *host;
@property(nonatomic, strong) UIView *hosted;
@property(nonatomic, strong) GLKeyboardWebInset *inset;
@end

@implementation GLKeyboardWebInsetTests

static const CGFloat kFakeTabBarHeight = 83;

- (void)setUp {
    [super setUp];
    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    self.host = [UIViewController new];
    self.window.rootViewController = self.host;
    [self.window makeKeyAndVisible];
    self.host.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, kFakeTabBarHeight, 0);

    self.hosted = [UIView new];
    self.hosted.translatesAutoresizingMaskIntoConstraints = NO;
    [self.host.view addSubview:self.hosted];
    UILayoutGuide *guide = self.host.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.hosted.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.hosted.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.hosted.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
    ]];
    self.inset = [GLKeyboardWebInset attachTo:self.hosted inContainer:self.host.view];
    [self.host.view layoutIfNeeded];
}

- (void)tearDown {
    self.window.hidden = YES;
    self.window = nil;
    [super tearDown];
}

- (CGFloat)hostedBottom { return CGRectGetMaxY(self.hosted.frame); }
- (CGFloat)containerBottom { return CGRectGetMaxY(self.host.view.bounds); }
- (CGFloat)safeAreaBottom {
    return CGRectGetMaxY(self.host.view.bounds) - self.host.view.safeAreaInsets.bottom;
}

- (void)testAtRestTheBottomEdgeStopsAtTheSafeArea {
    XCTAssertGreaterThan(self.containerBottom - self.safeAreaBottom, 0,
                         @"sanity: the safe area must actually be inset from the container's bottom, "
                         @"or this test passes no matter what the code does");
    XCTAssertFalse(self.inset.extendsBelowSafeArea);
    XCTAssertEqualWithAccuracy(self.hostedBottom, self.safeAreaBottom, 0.5,
                               @"at rest the hosted view must stop at the safe area, leaving the tab bar's "
                               @"strip alone -- a page painting behind the bar flips its system material");
}

- (void)testKeyboardShowingExtendsTheBottomEdgeToTheContainerBottom {
    [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardWillShowNotification
                                                        object:nil
                                                      userInfo:nil];
    XCTAssertTrue(self.inset.extendsBelowSafeArea);
    XCTAssertEqualWithAccuracy(self.hostedBottom, self.containerBottom, 0.5,
                               @"with the keyboard up the hosted view must reach the container's true bottom, "
                               @"so the page's own background fills the band down to the keyboard's edge");
    XCTAssertGreaterThan(self.hostedBottom, self.safeAreaBottom,
                         @"and it must actually have moved, not merely reported that it did");
}

- (void)testKeyboardHidingPutsTheBottomEdgeBack {
    [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardWillShowNotification
                                                        object:nil userInfo:nil];
    XCTAssertEqualWithAccuracy(self.hostedBottom, self.containerBottom, 0.5, @"sanity: it must be extended before this test can prove it comes back");

    [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardWillHideNotification
                                                        object:nil userInfo:nil];
    XCTAssertFalse(self.inset.extendsBelowSafeArea);
    XCTAssertEqualWithAccuracy(self.hostedBottom, self.safeAreaBottom, 0.5,
                               @"once the keyboard goes the tab bar is visible again and the hosted view must "
                               @"stop clear of it");
}

- (void)testRepeatedShowNotificationsAreIdempotent {
    // UIKeyboardWillShow fires more than once in ordinary use -- an accessory
    // view changing the keyboard's height, a language switch. Each must leave
    // exactly one bottom constraint active; two would be an unsatisfiable pair.
    for (int i = 0; i < 3; i++) {
        [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardWillShowNotification
                                                            object:nil userInfo:nil];
    }
    XCTAssertTrue(self.inset.extendsBelowSafeArea);
    XCTAssertEqualWithAccuracy(self.hostedBottom, self.containerBottom, 0.5,
                               @"repeated show notifications must not fight each other into a broken layout");
}

@end
