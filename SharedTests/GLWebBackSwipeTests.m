#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

#import "GLWebBackSwipe.h"

// Covers the ownership rule in GLWebBackSwipe: while a hosted page has history
// to go back to, the navigation controller's pop gestures are off so the
// WKWebView's own back swipe handles it; once the page is at its first screen,
// they come back on so the swipe returns to the More page.
//
// Runs against a real UINavigationController with a two-deep stack (the More
// root plus a pushed module), the same shape as the More tab. The web view half
// cannot be exercised here: a host-less bundle cannot run web content (see
// GLWebKeyboardFocusTests), so the canGoBack input is passed directly.
@interface GLWebBackSwipeTests : XCTestCase
@end

@implementation GLWebBackSwipeTests

- (UINavigationController *)moreShapedStack {
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:[[UIViewController alloc] init]];
    [nav pushViewController:[[UIViewController alloc] init] animated:NO];
    // interactivePopGestureRecognizer is nil until the view has loaded.
    [nav loadViewIfNeeded];
    XCTAssertNotNil(nav.interactivePopGestureRecognizer,
                    @"precondition: the edge pop gesture must exist once the view has loaded, "
                    @"or the assertions below are reporting on nil");
    return nav;
}

- (void)testPageWithHistoryOwnsTheSwipe {
    UINavigationController *nav = [self moreShapedStack];
    [GLWebBackSwipe applyPageCanGoBack:YES toNavigationController:nav];
    XCTAssertFalse(nav.interactivePopGestureRecognizer.enabled,
                   @"with page history, the edge pop must be off or the swipe leaves the module "
                   @"for the More page instead of going back inside it");
    UIGestureRecognizer *contentPop = [GLWebBackSwipe contentPopGestureRecognizerOf:nav];
    NSLog(@"GLWebBackSwipeTests: content pop gesture on this OS = %@", contentPop);
    if (contentPop != nil) {
        XCTAssertFalse(contentPop.enabled, @"the iOS 26 full-width pop must be off too, for the same reason");
    }
}

- (void)testPageAtFirstScreenHandsTheSwipeBack {
    UINavigationController *nav = [self moreShapedStack];
    [GLWebBackSwipe applyPageCanGoBack:YES toNavigationController:nav];
    [GLWebBackSwipe applyPageCanGoBack:NO toNavigationController:nav];
    XCTAssertTrue(nav.interactivePopGestureRecognizer.enabled,
                  @"at the page's first screen the edge pop must be back on, or the module "
                  @"can't be swiped away at all");
    UIGestureRecognizer *contentPop = [GLWebBackSwipe contentPopGestureRecognizerOf:nav];
    if (contentPop != nil) {
        XCTAssertTrue(contentPop.enabled, @"the iOS 26 full-width pop must be restored too");
    }
}

- (void)testNilNavigationControllerIsANoOp {
    XCTAssertNoThrow([GLWebBackSwipe applyPageCanGoBack:YES toNavigationController:nil]);
}

@end
