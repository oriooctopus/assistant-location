#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#import "GLWebKeyboardFocus.h"

// Covers the accessory-bar suppression in GLWebKeyboardFocus.
//
// The bug: window.visualViewport does not count the keyboard's input accessory
// bar, so the add-todo composer -- lifted by exactly the keyboard height the
// visual viewport reports -- still had its list chip and Save button covered
// by that bar sitting on top (Oliver, 2026-09-07: "its still covering some of
// it"). No web API reports the bar's height, so the fix had to be native.
//
// ## What this test does NOT do, and why
//
// The assertion worth having is "focus a field in a real WKWebView, then check
// the content view reports no accessory bar". That is not achievable in this
// bundle. SharedTests is a host-less logic-test bundle (deliberately -- see
// scripts/add_shared_tests_target.rb on why it has no TEST_HOST), and WKWebView
// cannot start a web content process without a host application: every
// -evaluateJavaScript: call made from here never calls back at all, so the page
// is never scriptable and no field can be focused. Verified on CI, not assumed
// -- run 34182466407 polled for a scriptable page for 60 seconds and every
// probe timed out.
//
// Two earlier attempts at the stronger test are worth recording so they are not
// retried:
//  - Asserting -inputAccessoryView is nil on a loaded-but-unfocused web view
//    PASSES with the suppression deliberately disabled (run 34181963028).
//    WebKit only builds the bar once a field takes focus; before that it is nil
//    either way, so that test proves nothing.
//  - Adding the focus step then fails for the wrong reason (run 34182191164):
//    the JS never runs, per the host-less limitation above.
//
// So this asserts the mechanism instead: that WKContentView's
// -inputAccessoryView actually resolves to our override after +install. That
// catches every realistic regression -- the install call being dropped, WebKit
// renaming the private class, the class_addMethod/method_setImplementation
// branch picking wrong -- and it fails when the suppression is disabled, which
// the nil-check version did not. It does not, and does not claim to, prove the
// bar is visually gone. Only the device does that.
//
// BLOCKER: there is no automated coverage anywhere in this repo for the bar
// actually being absent on screen. Closing that gap means giving SharedTests a
// host app, or a UI test that drives a real web view in the running app.
@interface GLWebKeyboardFocusTests : XCTestCase
@end

@implementation GLWebKeyboardFocusTests

- (void)testAccessoryViewSuppressionIsInstalledOnWKContentView {
    [GLWebKeyboardFocus install];

    // Sanity first: if WebKit renamed its private view class, the suppression
    // silently does nothing, and the assertion below would be reporting on a
    // class that no longer exists rather than on our override.
    XCTAssertNotNil(NSClassFromString(@"WKContentView"),
                    @"WKContentView not found -- WebKit's private view class was renamed, which "
                    @"disables both the accessory-bar suppression and the programmatic-focus swizzle");

    XCTAssertTrue([GLWebKeyboardFocus isAccessoryViewSuppressionInstalled],
                  @"WKContentView's -inputAccessoryView must resolve to GLWebKeyboardFocus's override "
                  @"after +install -- without it, iOS draws its prev/next/Done bar over the bottom "
                  @"~55pt of every web sheet, which is where the add-todo composer's list chip and "
                  @"Save button sit");
}

- (void)testInstallIsIdempotent {
    [GLWebKeyboardFocus install];
    [GLWebKeyboardFocus install];
    // +install is called from every GLWebModuleViewController's -viewDidLoad
    // and this app has several web modules, so it genuinely runs more than
    // once. A second install must not, for example, capture our own override
    // as the "original" implementation and recurse.
    XCTAssertTrue([GLWebKeyboardFocus isAccessoryViewSuppressionInstalled],
                  @"a second +install must leave the suppression in place, not undo or double-wrap it");
}

@end
