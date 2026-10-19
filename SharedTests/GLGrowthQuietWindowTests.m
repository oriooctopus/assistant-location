// Quiet-window rules behind "Growth doesn't auto-open after a review": a card
// answer buys 30 minutes, a tile pick 4 hours, and a shorter window never
// shortens a longer one. Pure logic against a throwaway NSUserDefaults suite
// and an injected clock.
#import <XCTest/XCTest.h>
#import "GLGrowthQuietWindow.h"

static NSTimeInterval const kHour = 3600;

@interface GLGrowthQuietWindowTests : XCTestCase
@property (nonatomic, strong) NSUserDefaults *defaults;
@end

@implementation GLGrowthQuietWindowTests

- (void)setUp {
    NSString *suite = [@"GLGrowthQuietWindowTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    self.defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
}

- (void)testNeverReviewedIsNotQuiet {
    XCTAssertFalse([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1000]);
}

- (void)testDefaultWindowIsThirtyMinutes {
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:nil defaults:self.defaults now:1000];
    XCTAssertTrue([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1000 + 29 * 60]);
    XCTAssertFalse([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1000 + 31 * 60]);
}

- (void)testPickWindowIsFourHours {
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:@(4 * kHour) defaults:self.defaults now:1000];
    XCTAssertTrue([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1000 + 3.9 * kHour]);
    XCTAssertFalse([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1000 + 4.1 * kHour]);
}

- (void)testShorterWindowNeverShortensALongerOne {
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:@(4 * kHour) defaults:self.defaults now:1000];
    // A card answer 10 minutes later would end at 1000+10min+30min, well before the pick's 4h.
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:nil defaults:self.defaults now:1000 + 600];
    XCTAssertTrue([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1000 + 3.9 * kHour]);
}

- (void)testLongerWindowExtendsAShorterOne {
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:nil defaults:self.defaults now:1000];
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:@(4 * kHour) defaults:self.defaults now:1000 + 600];
    XCTAssertTrue([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1000 + 600 + 3.9 * kHour]);
}

- (void)testLegacyLastReviewedKeyIsIgnoredAndRemoved {
    [self.defaults setDouble:1000 forKey:@"GLGrowthLastReviewedAt"];
    XCTAssertFalse([GLGrowthQuietWindow isQuietInDefaults:self.defaults now:1010], @"the old key must not start a window");
    [GLGrowthQuietWindow noteReviewWithQuietSeconds:nil defaults:self.defaults now:1000];
    XCTAssertNil([self.defaults objectForKey:@"GLGrowthLastReviewedAt"]);
}

@end
