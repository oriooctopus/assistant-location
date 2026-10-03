// Regression coverage for the resume default-tab reset vs. lock-screen deep
// links. iOS doesn't promise an order between willEnterForeground,
// openURLContexts and didBecomeActive, so every ordering is driven here
// directly against GLDefaultTabArbiter (see its header).
#import <XCTest/XCTest.h>
#import "GLDefaultTabArbiter.h"

static NSTimeInterval const kThreshold = 180;

@interface GLDefaultTabArbiterTests : XCTestCase
@property (nonatomic, strong) GLDefaultTabArbiter *arbiter;
@end

@implementation GLDefaultTabArbiterTests

- (void)setUp {
    self.arbiter = [[GLDefaultTabArbiter alloc] initWithThresholdSeconds:kThreshold];
}

- (void)testLongAbsenceWithNoDeepLinkSelectsDefault {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:3];
    [self.arbiter willEnterForegroundAt:1000 + 30 * 60];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:3], GLDefaultTabDecisionSelectDefault);
    XCTAssertEqualWithAccuracy(self.arbiter.lastElapsedSeconds, 30 * 60, 0.001);
}

- (void)testShortAbsenceKeepsCurrentTab {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000 + kThreshold - 1];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0], GLDefaultTabDecisionKeepCurrent);
}

- (void)testExactlyThresholdCountsAsLongAbsence {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000 + kThreshold];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0], GLDefaultTabDecisionSelectDefault);
}

// The observed phone ordering: openURLContexts after willEnterForeground,
// before didBecomeActive.
- (void)testDeepLinkBetweenForegroundAndActiveWins {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:5];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:6], GLDefaultTabDecisionExplicitNavigationWins);
}

// URL routed before willEnterForeground: the count is already higher when
// the decision is taken, same outcome.
- (void)testDeepLinkBeforeForegroundWins {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:5];
    NSUInteger countAfterURL = 6;
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:countAfterURL], GLDefaultTabDecisionExplicitNavigationWins);
}

// URL after the decision: the reset already ran, the deep link navigates
// afterwards and wins on its own. The arbiter must not fire a second reset
// on a later activation in the same cycle.
- (void)testDecisionIsTakenOnlyOncePerCycle {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0], GLDefaultTabDecisionSelectDefault);
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1], GLDefaultTabDecisionNone);
}

// Cold launch: willEnterForeground and didBecomeActive with no background.
- (void)testColdLaunchIsNotAResume {
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0], GLDefaultTabDecisionNone);
}

// Control Center / an alert / a call: didBecomeActive with no foreground
// transition in between.
- (void)testActivationWithoutForegroundIsNotAResume {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0], GLDefaultTabDecisionNone);
}

// A navigation BEFORE going to the background (the user tapped a tab, then
// locked) must not cancel the next reset.
- (void)testNavigationBeforeBackgroundDoesNotCancelReset {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:9];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:9], GLDefaultTabDecisionSelectDefault);
}

// Second cycle starts clean: a deep link in cycle 1 doesn't leak into 2.
- (void)testSecondCycleIsIndependent {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1], GLDefaultTabDecisionExplicitNavigationWins);
    [self.arbiter didEnterBackgroundAt:6000 explicitNavigationCount:1];
    [self.arbiter willEnterForegroundAt:9000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1], GLDefaultTabDecisionSelectDefault);
}

// A background that never foregrounded (killed / re-backgrounded before
// willEnterForeground) leaves no stale pending decision.
- (void)testBackgroundAgainClearsPending {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    [self.arbiter didEnterBackgroundAt:5001 explicitNavigationCount:0];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0], GLDefaultTabDecisionNone);
}

@end
