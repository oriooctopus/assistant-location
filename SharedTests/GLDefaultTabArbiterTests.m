// Regression coverage for the resume default-tab reset vs. lock-screen deep
// links. iOS doesn't promise an order between willEnterForeground,
// openURLContexts and didBecomeActive, so every ordering is driven here
// directly against GLDefaultTabArbiter (see its header).
#import <XCTest/XCTest.h>
#import "GLDefaultTabArbiter.h"

static NSTimeInterval const kThreshold = 180;
static NSTimeInterval const kCooldown = 4 * 60 * 60;

@interface GLDefaultTabArbiterTests : XCTestCase
@property (nonatomic, strong) GLDefaultTabArbiter *arbiter;
@end

@implementation GLDefaultTabArbiterTests

- (void)setUp {
    self.arbiter = [[GLDefaultTabArbiter alloc] initWithThresholdSeconds:kThreshold cooldownSeconds:kCooldown];
}

- (void)testLongAbsenceWithNoDeepLinkSelectsDefault {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:3];
    [self.arbiter willEnterForegroundAt:1000 + 30 * 60];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:3 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
    XCTAssertEqualWithAccuracy(self.arbiter.lastElapsedSeconds, 30 * 60, 0.001);
}

- (void)testShortAbsenceKeepsCurrentTab {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000 + kThreshold - 1];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionKeepCurrent);
}

- (void)testExactlyThresholdCountsAsLongAbsence {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000 + kThreshold];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
}

// The observed phone ordering: openURLContexts after willEnterForeground,
// before didBecomeActive.
- (void)testDeepLinkBetweenForegroundAndActiveWins {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:5];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:6 currentScreenHolds:NO], GLDefaultTabDecisionExplicitNavigationWins);
}

// URL routed before willEnterForeground: the count is already higher when
// the decision is taken, same outcome.
- (void)testDeepLinkBeforeForegroundWins {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:5];
    NSUInteger countAfterURL = 6;
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:countAfterURL currentScreenHolds:NO], GLDefaultTabDecisionExplicitNavigationWins);
}

// URL after the decision: the reset already ran, the deep link navigates
// afterwards and wins on its own. The arbiter must not fire a second reset
// on a later activation in the same cycle.
- (void)testDecisionIsTakenOnlyOncePerCycle {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1 currentScreenHolds:NO], GLDefaultTabDecisionNone);
}

// Cold launch: willEnterForeground and didBecomeActive with no background.
- (void)testColdLaunchIsNotAResume {
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionNone);
}

// Control Center / an alert / a call: didBecomeActive with no foreground
// transition in between.
- (void)testActivationWithoutForegroundIsNotAResume {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionNone);
}

// A navigation BEFORE going to the background (the user tapped a tab, then
// locked) must not cancel the next reset.
- (void)testNavigationBeforeBackgroundDoesNotCancelReset {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:9];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:9 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
}

// Second cycle starts clean: a deep link in cycle 1 doesn't leak into 2.
- (void)testSecondCycleIsIndependent {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1 currentScreenHolds:NO], GLDefaultTabDecisionExplicitNavigationWins);
    [self.arbiter didEnterBackgroundAt:6000 explicitNavigationCount:1];
    [self.arbiter willEnterForegroundAt:9000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
}

// A background that never foregrounded (killed / re-backgrounded before
// willEnterForeground) leaves no stale pending decision.
- (void)testBackgroundAgainClearsPending {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    [self.arbiter didEnterBackgroundAt:5001 explicitNavigationCount:0];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionNone);
}

// Journal on screen (records with the phone locked): a long absence with
// nothing explicit must not reset.
- (void)testLongAbsenceWithHoldingScreenKeepsIt {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000 + 288];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:YES], GLDefaultTabDecisionCurrentTabHolds);
}

- (void)testShortAbsenceWithHoldingScreenIsKeepCurrent {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000 + kThreshold - 1];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:YES], GLDefaultTabDecisionKeepCurrent);
}

- (void)testExplicitNavigationBeatsHoldingScreen {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1 currentScreenHolds:YES], GLDefaultTabDecisionExplicitNavigationWins);
}

- (void)testNonHoldingScreenStillSelectsDefault {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:5000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
}

// Resume #1 selects the default; a second long resume inside the cooldown
// must not.
- (void)testSecondResumeWithinCooldownIsRecentlyShownDefault {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:2000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
    [self.arbiter didSelectDefaultAt:2000];
    [self.arbiter didEnterBackgroundAt:2100 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:2100 + 600];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionRecentlyShownDefault);
}

// A cold launch selection (no resume involved) starts the cooldown too.
- (void)testColdLaunchSelectionStartsCooldown {
    [self.arbiter didSelectDefaultAt:10];
    [self.arbiter didEnterBackgroundAt:100 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionRecentlyShownDefault);
}

- (void)testResumeAfterCooldownSelectsDefaultAgain {
    [self.arbiter didSelectDefaultAt:2000];
    [self.arbiter didEnterBackgroundAt:2100 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:2000 + kCooldown];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
}

// KeepCurrent and Hold never call didSelectDefaultAt:, so they start no
// cooldown: the next long resume still selects.
- (void)testKeepCurrentAndHoldDoNotStartCooldown {
    [self.arbiter didEnterBackgroundAt:1000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000 + kThreshold - 1];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionKeepCurrent);
    [self.arbiter didEnterBackgroundAt:2000 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:3000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:YES], GLDefaultTabDecisionCurrentTabHolds);
    [self.arbiter didEnterBackgroundAt:3100 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:4000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:NO], GLDefaultTabDecisionSelectDefault);
}

// Hold and explicit navigation outrank the cooldown.
- (void)testHoldAndExplicitNavigationOutrankCooldown {
    [self.arbiter didSelectDefaultAt:10];
    [self.arbiter didEnterBackgroundAt:100 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:1000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:0 currentScreenHolds:YES], GLDefaultTabDecisionCurrentTabHolds);
    [self.arbiter didEnterBackgroundAt:1100 explicitNavigationCount:0];
    [self.arbiter willEnterForegroundAt:2000];
    XCTAssertEqual([self.arbiter takeDecisionWithExplicitNavigationCount:1 currentScreenHolds:NO], GLDefaultTabDecisionExplicitNavigationWins);
}

@end
