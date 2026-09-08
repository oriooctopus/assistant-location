#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#import "GLWebKeyboardFocus.h"

// Proves the keyboard's input accessory bar is actually gone from a real
// WKWebView, not merely that a swizzle was installed.
//
// The bug: window.visualViewport does not count the accessory bar, so the
// add-todo composer -- lifted by exactly the keyboard height the visual
// viewport reports -- still had its list chip and Save button covered by the
// bar sitting on top (Oliver, 2026-09-07: "its still covering some of it").
// No web API reports that bar's height, so this had to be fixed natively.
//
// The assertion goes through WKContentView, WebKit's private view class that
// actually becomes first responder for web content. Asking the WKWebView
// itself is not equivalent: WKWebView is not the responder that supplies the
// accessory view, so it returns nil whether or not this fix is installed, and
// a test written against it would pass on a completely broken build.
@interface GLWebKeyboardFocusTests : XCTestCase
@end

@implementation GLWebKeyboardFocusTests

/** WebKit's private content view: the WKWebView descendant that conforms to
 *  UITextInput and is therefore the responder whose -inputAccessoryView iOS
 *  consults. Found by class name rather than by position because the view
 *  hierarchy WebKit builds under WKWebView has changed shape across releases. */
static UIView *GLFindContentView(UIView *root) {
    Class contentViewClass = NSClassFromString(@"WKContentView");
    if (!contentViewClass) return nil;
    if ([root isKindOfClass:contentViewClass]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = GLFindContentView(subview);
        if (found) return found;
    }
    return nil;
}

// The first version of this test asserted -inputAccessoryView was nil on a
// loaded-but-unfocused web view. It passed with the suppression deliberately
// disabled (CI run 34181963028), because WebKit only builds the accessory bar
// once a field actually takes focus -- before that it is nil either way. The
// focus step and the isFirstResponder sanity assertion below are what make the
// assertion mean anything; neither is optional.
- (void)testInputAccessoryBarIsSuppressedOnRealWebContent {
    [GLWebKeyboardFocus install];

    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    // A key + visible window: WebKit does not build its full interaction view
    // hierarchy (WKContentView included) for a web view that was never placed
    // on screen, so without this there is nothing to assert against.
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    window.rootViewController = [UIViewController new];
    [window.rootViewController.view addSubview:webView];
    [window makeKeyAndVisible];

    XCTestExpectation *loaded = [self expectationWithDescription:@"web content loaded"];
    [webView loadHTMLString:@"<html><body><input id='t' type='text'></body></html>" baseURL:nil];
    // Poll rather than use WKNavigationDelegate: the delegate fires on
    // navigation completion, which is not the same moment WebKit has finished
    // attaching its interaction views, and it is those we need.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [loaded fulfill];
    });
    [self waitForExpectationsWithTimeout:10.0 handler:nil];

    // Focus a field. This is what makes WebKit build its input views at all,
    // and it exercises the other half of this class at the same time: the
    // _elementDidFocus swizzle is what lets a PROGRAMMATIC focus like this one
    // raise the keyboard rather than being ignored as non-user-initiated.
    XCTestExpectation *focused = [self expectationWithDescription:@"input focused"];
    [webView evaluateJavaScript:@"document.getElementById('t').focus(); document.activeElement.id"
              completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error, @"focusing the test input failed: %@", error);
        XCTAssertEqualObjects(result, @"t", @"the input did not actually become document.activeElement");
        [focused fulfill];
    }];
    [self waitForExpectationsWithTimeout:10.0 handler:nil];

    // Focus propagates from the web process to the UI process asynchronously,
    // so the responder state is not up to date on the very next runloop turn.
    XCTestExpectation *settled = [self expectationWithDescription:@"input views settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [settled fulfill];
    });
    [self waitForExpectationsWithTimeout:10.0 handler:nil];

    UIView *contentView = GLFindContentView(webView);
    XCTAssertNotNil(contentView,
                    @"WKContentView not found under the web view -- WebKit's private view class may have "
                    @"been renamed, which would also silently disable the suppression this test covers");

    // Load-bearing sanity check, NOT decoration. An unfocused WKContentView
    // reports a nil accessory view whether or not the suppression is
    // installed, so without proving focus actually took, the assertion below
    // passes on a completely unfixed build -- which is exactly what happened
    // the first time this test was written.
    XCTAssertTrue(contentView.isFirstResponder,
                  @"WKContentView never became first responder, so the accessory-bar assertion below "
                  @"would pass vacuously -- fix the focus step rather than trusting a green result");

    XCTAssertNil(contentView.inputAccessoryView,
                 @"WKContentView must report no input accessory view while a field is focused -- a "
                 @"non-nil bar here is the ~55pt strip that covered the add-todo composer's chip and "
                 @"Save button");
}

@end
