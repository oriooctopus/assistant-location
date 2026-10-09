// The Today pager's pure logic: stepping through the quote list, clamping at
// both ends (no wrap), the Today link, and the "0034 / 101" meta line.
#import <XCTest/XCTest.h>
#import "QuotesTheme.h"

@interface QuotesPagingTests : XCTestCase
@end

@implementation QuotesPagingTests

- (void)testNextAndPreviousStepByOne {
    XCTAssertEqual(QuotesPageIndexAfter(5, +1, 101), 6);
    XCTAssertEqual(QuotesPageIndexAfter(5, -1, 101), 4);
    XCTAssertTrue(QuotesPageCanMove(5, +1, 101));
    XCTAssertTrue(QuotesPageCanMove(5, -1, 101));
}

- (void)testClampsAtTheFirstQuote {
    XCTAssertEqual(QuotesPageIndexAfter(0, -1, 101), 0);
    XCTAssertFalse(QuotesPageCanMove(0, -1, 101));
    XCTAssertTrue(QuotesPageCanMove(0, +1, 101));
}

- (void)testClampsAtTheLastQuote {
    XCTAssertEqual(QuotesPageIndexAfter(100, +1, 101), 100);
    XCTAssertFalse(QuotesPageCanMove(100, +1, 101));
    XCTAssertTrue(QuotesPageCanMove(100, -1, 101));
}

- (void)testSingleQuoteCannotMove {
    XCTAssertFalse(QuotesPageCanMove(0, +1, 1));
    XCTAssertFalse(QuotesPageCanMove(0, -1, 1));
    XCTAssertEqual(QuotesPageIndexAfter(0, +1, 1), 0);
}

- (void)testTodayLinkShowsOnlyOffToday {
    XCTAssertFalse(QuotesPageShowsTodayLink(33, 33));
    XCTAssertTrue(QuotesPageShowsTodayLink(34, 33));
    XCTAssertTrue(QuotesPageShowsTodayLink(0, 33));
}

- (void)testTodayTapReturnsToTodaysIndexFromAnywhere {
    NSInteger today = 33;
    NSInteger viewing = today;
    for (NSInteger i = 0; i < 6; i++) viewing = QuotesPageIndexAfter(viewing, +1, 101);
    XCTAssertEqual(viewing, 39);
    XCTAssertEqual(QuotesPageIndexForTodayTap(viewing, today), today);
    viewing = 0;
    XCTAssertEqual(QuotesPageIndexForTodayTap(viewing, today), today);
}

- (void)testMetaLineIsOneBasedAndZeroPadded {
    XCTAssertEqualObjects(QuotesPageMetaText(33, 101), @"0034 / 101");
    XCTAssertEqualObjects(QuotesPageMetaText(0, 101), @"0001 / 101");
    XCTAssertEqualObjects(QuotesPageMetaText(100, 101), @"0101 / 101");
}

@end
