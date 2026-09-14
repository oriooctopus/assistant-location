// Pure-logic tests for QuotesRuleEngine + GLQuoteRule's window math --
// covers midnight wrap, first-rule-wins, the no-match fallback, and pool
// selection for both rule kinds. No disk, no keychain, no UIKit.
#import <XCTest/XCTest.h>
#import "QuotesModels.h"
#import "QuotesRuleEngine.h"

@interface QuotesRuleEngineTests : XCTestCase
@end

@implementation QuotesRuleEngineTests

- (GLQuote *)quoteWithId:(NSString *)quoteId author:(NSString *)author genres:(NSArray<NSString *> *)genres {
    return [[GLQuote alloc] initWithId:quoteId text:[@"text-" stringByAppendingString:quoteId] author:author genres:genres source:GLQuoteSourceStock];
}

- (GLQuoteRule *)filterRuleWithId:(NSString *)ruleId
                          authors:(NSArray<NSString *> *)authors
                           genres:(NSArray<NSString *> *)genres
                             days:(NSArray<NSNumber *> *)days
                      startMinute:(NSInteger)start
                        endMinute:(NSInteger)end
                    rotateMinutes:(NSInteger)rotate {
    return [[GLQuoteRule alloc] initWithId:ruleId
                                       name:ruleId
                                       kind:GLQuoteRuleKindFilter
                                    authors:authors
                                     genres:genres
                                     prompt:@""
                                   quoteIds:@[]
                                       days:days
                                startMinute:start
                                  endMinute:end
                              rotateMinutes:rotate];
}

#pragma mark - Window / wrap

- (void)testMidnightWrapWindowContainsBothSidesOfMidnight {
    // 22:00 (1320) through 06:00 (360), every day.
    GLQuoteRule *rule = [self filterRuleWithId:@"night" authors:@[] genres:@[] days:@[@1, @2, @3, @4, @5, @6, @7]
                                    startMinute:1320 endMinute:360 rotateMinutes:60];
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:1320]);   // exactly at start
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:1439]);   // 23:59
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:0]);      // midnight
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:359]);    // 05:59
    XCTAssertFalse([rule containsWeekday:2 minuteOfDay:360]);   // exactly at end -- exclusive
    XCTAssertFalse([rule containsWeekday:2 minuteOfDay:1319]);  // just before start
    XCTAssertFalse([rule containsWeekday:2 minuteOfDay:720]);   // noon, well outside
}

- (void)testNonWrappingWindowIsHalfOpen {
    GLQuoteRule *rule = [self filterRuleWithId:@"morning" authors:@[] genres:@[] days:@[@2]
                                    startMinute:480 endMinute:600 rotateMinutes:60]; // 08:00-10:00
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:480]);
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:599]);
    XCTAssertFalse([rule containsWeekday:2 minuteOfDay:600]); // exclusive end
    XCTAssertFalse([rule containsWeekday:2 minuteOfDay:479]);
}

- (void)testStartEqualsEndMeansWholeDay {
    GLQuoteRule *rule = [self filterRuleWithId:@"allday" authors:@[] genres:@[] days:@[@1]
                                    startMinute:600 endMinute:600 rotateMinutes:60];
    XCTAssertTrue([rule containsWeekday:1 minuteOfDay:0]);
    XCTAssertTrue([rule containsWeekday:1 minuteOfDay:1439]);
    XCTAssertTrue([rule containsWeekday:1 minuteOfDay:600]);
}

- (void)testDayNotInListNeverMatches {
    GLQuoteRule *rule = [self filterRuleWithId:@"weekday-only" authors:@[] genres:@[] days:@[@2, @3, @4, @5, @6]
                                    startMinute:0 endMinute:1440 rotateMinutes:60];
    XCTAssertFalse([rule containsWeekday:1 minuteOfDay:600]); // Sunday
    XCTAssertFalse([rule containsWeekday:7 minuteOfDay:600]); // Saturday
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:600]);  // Monday
}

#pragma mark - First-rule-wins / no-match fallback

- (void)testFirstMatchingRuleInListOrderWins {
    NSArray<GLQuote *> *quotes = @[[self quoteWithId:@"1" author:@"A" genres:@[]], [self quoteWithId:@"2" author:@"B" genres:@[]]];
    GLQuoteRule *earlyMorning = [self filterRuleWithId:@"early" authors:@[@"A"] genres:@[] days:@[@2] startMinute:0 endMinute:1440 rotateMinutes:30];
    GLQuoteRule *allDay = [self filterRuleWithId:@"late" authors:@[@"B"] genres:@[] days:@[@2] startMinute:0 endMinute:1440 rotateMinutes:90];

    // Both rules' windows contain minuteOfDay 600 -- list order decides, not
    // which is "more specific".
    QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:2 minuteOfDay:600
                                                             rules:@[earlyMorning, allDay]
                                                            quotes:quotes
                                              defaultRotateMinutes:15];
    XCTAssertEqualObjects(selection.matchedRule.ruleId, @"early");
    XCTAssertEqual(selection.rotateMinutes, 30);
    XCTAssertEqual(selection.pool.count, 1u);
    XCTAssertEqualObjects(selection.pool.firstObject.quoteId, @"1");
}

- (void)testNoMatchingRuleFallsBackToAllQuotesAndDefaultRotate {
    NSArray<GLQuote *> *quotes = @[[self quoteWithId:@"1" author:@"A" genres:@[]], [self quoteWithId:@"2" author:@"B" genres:@[]]];
    GLQuoteRule *narrow = [self filterRuleWithId:@"narrow" authors:@[@"A"] genres:@[] days:@[@2] startMinute:0 endMinute:60 rotateMinutes:30];

    QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:2 minuteOfDay:600 // outside narrow's 0-60 window
                                                             rules:@[narrow]
                                                            quotes:quotes
                                              defaultRotateMinutes:45];
    XCTAssertNil(selection.matchedRule);
    XCTAssertEqual(selection.pool.count, 2u);
    XCTAssertEqual(selection.rotateMinutes, 45);
}

#pragma mark - Pool selection

- (void)testFilterPoolMatchesAuthorOrGenre {
    NSArray<GLQuote *> *quotes = @[
        [self quoteWithId:@"1" author:@"Seneca" genres:@[@"stoicism"]],
        [self quoteWithId:@"2" author:@"Wilde" genres:@[@"humor"]],
        [self quoteWithId:@"3" author:@"Twain" genres:@[@"humor", @"wisdom"]],
    ];
    GLQuoteRule *rule = [self filterRuleWithId:@"funny" authors:@[@"Seneca"] genres:@[@"humor"] days:@[@1] startMinute:0 endMinute:1440 rotateMinutes:60];
    QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:1 minuteOfDay:0 rules:@[rule] quotes:quotes defaultRotateMinutes:60];
    NSSet<NSString *> *ids = [NSSet setWithArray:[selection.pool valueForKey:@"quoteId"]];
    XCTAssertEqualObjects(ids, ([NSSet setWithArray:@[@"1", @"2", @"3"]]));
}

- (void)testUnrestrictedFilterRuleMatchesEveryQuote {
    NSArray<GLQuote *> *quotes = @[[self quoteWithId:@"1" author:@"A" genres:@[]], [self quoteWithId:@"2" author:@"B" genres:@[]]];
    GLQuoteRule *rule = [self filterRuleWithId:@"anything" authors:@[] genres:@[] days:@[@1] startMinute:0 endMinute:1440 rotateMinutes:60];
    QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:1 minuteOfDay:0 rules:@[rule] quotes:quotes defaultRotateMinutes:60];
    XCTAssertEqual(selection.pool.count, 2u);
}

- (void)testAIRuleWithNoResolvedQuoteIdsIsAwaitingResolution {
    NSArray<GLQuote *> *quotes = @[[self quoteWithId:@"1" author:@"A" genres:@[]]];
    GLQuoteRule *aiRule = [[GLQuoteRule alloc] initWithId:@"ai" name:@"ai" kind:GLQuoteRuleKindAI authors:@[] genres:@[]
                                                     prompt:@"about courage" quoteIds:@[] days:@[@1]
                                                startMinute:0 endMinute:1440 rotateMinutes:60];
    QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:1 minuteOfDay:0 rules:@[aiRule] quotes:quotes defaultRotateMinutes:60];
    XCTAssertTrue(selection.awaitingAIResolution);
    XCTAssertEqual(selection.pool.count, 0u);
}

- (void)testAIRuleWithResolvedQuoteIdsPicksThoseQuotesOnly {
    NSArray<GLQuote *> *quotes = @[
        [self quoteWithId:@"1" author:@"A" genres:@[]],
        [self quoteWithId:@"2" author:@"B" genres:@[]],
        [self quoteWithId:@"3" author:@"C" genres:@[]],
    ];
    GLQuoteRule *aiRule = [[GLQuoteRule alloc] initWithId:@"ai" name:@"ai" kind:GLQuoteRuleKindAI authors:@[] genres:@[]
                                                     prompt:@"about courage" quoteIds:@[@"2"] days:@[@1]
                                                startMinute:0 endMinute:1440 rotateMinutes:60];
    QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:1 minuteOfDay:0 rules:@[aiRule] quotes:quotes defaultRotateMinutes:60];
    XCTAssertFalse(selection.awaitingAIResolution);
    XCTAssertEqual(selection.pool.count, 1u);
    XCTAssertEqualObjects(selection.pool.firstObject.quoteId, @"2");
}

#pragma mark - Rotation

- (void)testCurrentQuoteRotatesDeterministicallyByEpochBucket {
    NSArray<GLQuote *> *pool = @[[self quoteWithId:@"1" author:@"A" genres:@[]], [self quoteWithId:@"2" author:@"B" genres:@[]]];
    QuotesSelection *selection = [[QuotesSelection alloc] initWithMatchedRule:nil pool:pool rotateMinutes:60 awaitingAIResolution:NO];

    GLQuote *a = [QuotesRuleEngine currentQuoteForSelection:selection epochMinute:0];
    GLQuote *b = [QuotesRuleEngine currentQuoteForSelection:selection epochMinute:59]; // same 60-minute bucket
    GLQuote *c = [QuotesRuleEngine currentQuoteForSelection:selection epochMinute:60];  // next bucket

    XCTAssertEqualObjects(a.quoteId, b.quoteId); // same bucket -> same quote
    XCTAssertNotEqualObjects(a.quoteId, c.quoteId); // next bucket -> the other quote (pool of 2)
}

- (void)testCurrentQuoteForEmptyPoolIsNil {
    QuotesSelection *selection = [[QuotesSelection alloc] initWithMatchedRule:nil pool:@[] rotateMinutes:60 awaitingAIResolution:NO];
    XCTAssertNil([QuotesRuleEngine currentQuoteForSelection:selection epochMinute:1000]);
}

@end
