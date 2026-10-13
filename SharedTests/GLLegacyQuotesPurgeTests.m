// The main app must drop the 14-days-ahead "quotes-daily-YYYY-MM-DD" requests
// the pre-split in-app Quotes notifier left queued, and nothing else it owns.
#import <XCTest/XCTest.h>
#import "GLLegacyQuotesPurge.h"

@interface GLLegacyQuotesPurgeTests : XCTestCase
@end

@implementation GLLegacyQuotesPurgeTests

- (void)testSelectsOnlyLegacyQuotesDailyRequests {
    NSArray<NSString *> *pending = @[
        @"quotes-daily-2026-10-13",
        @"EsmeDailyCheckin-2026-10-13",
        @"reminder",
        @"quotes-daily-2026-10-22",
        @"quotes-daily",
    ];
    XCTAssertEqualObjects([GLLegacyQuotesPurge legacyIdentifiersIn:pending],
                          (@[ @"quotes-daily-2026-10-13", @"quotes-daily-2026-10-22" ]));
}

- (void)testNoLegacyRequestsSelectsNothing {
    XCTAssertEqualObjects([GLLegacyQuotesPurge legacyIdentifiersIn:@[ @"reminder" ]], @[]);
    XCTAssertEqualObjects([GLLegacyQuotesPurge legacyIdentifiersIn:@[]], @[]);
}

@end
