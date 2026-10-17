// Double-tapping a tab bar icon sends that mini-app to its home page
// (GLModuleRegistry's GLTabSelectionCoordinator). These cover which tap
// sequences count as the double-tap. Plain NSObjects stand in for the tabs'
// view controllers -- the detector only compares identity.
#import <XCTest/XCTest.h>
#import "GLTabDoubleTap.h"

@interface GLTabDoubleTapTests : XCTestCase
@end

@implementation GLTabDoubleTapTests {
    GLTabDoubleTap *_detector;
    NSObject *_events, *_sessions;
}

- (void)setUp {
    _detector = [[GLTabDoubleTap alloc] initWithWindow:0.4];
    _events = [NSObject new];
    _sessions = [NSObject new];
}

- (void)testSingleTapDoesNotFire {
    XCTAssertFalse([_detector registerTapOn:_events atTime:10.0]);
}

- (void)testTwoQuickTapsOnSameTabFire {
    XCTAssertFalse([_detector registerTapOn:_events atTime:10.0]);
    XCTAssertTrue([_detector registerTapOn:_events atTime:10.3]);
}

- (void)testTapsExactlyAtWindowEdgeFire {
    [_detector registerTapOn:_events atTime:10.0];
    XCTAssertTrue([_detector registerTapOn:_events atTime:10.4]);
}

- (void)testSlowSecondTapDoesNotFire {
    [_detector registerTapOn:_events atTime:10.0];
    XCTAssertFalse([_detector registerTapOn:_events atTime:10.5]);
}

// A slow tap still starts a fresh pair: tap, pause, then a quick double-tap.
- (void)testSlowTapStartsNewPair {
    [_detector registerTapOn:_events atTime:10.0];
    XCTAssertFalse([_detector registerTapOn:_events atTime:11.0]);
    XCTAssertTrue([_detector registerTapOn:_events atTime:11.2]);
}

- (void)testQuickTapsOnDifferentTabsDoNotFire {
    [_detector registerTapOn:_sessions atTime:10.0];
    XCTAssertFalse([_detector registerTapOn:_events atTime:10.2]);
}

- (void)testThirdRapidTapDoesNotFireAgain {
    [_detector registerTapOn:_events atTime:10.0];
    XCTAssertTrue([_detector registerTapOn:_events atTime:10.2]);
    XCTAssertFalse([_detector registerTapOn:_events atTime:10.3]);
    XCTAssertTrue([_detector registerTapOn:_events atTime:10.4]);
}

@end
