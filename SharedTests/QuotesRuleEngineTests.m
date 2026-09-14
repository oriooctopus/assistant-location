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

- (void)testMidnightWrapWindowsPostMidnightTailBelongsToTheStartingDay {
    // A Monday-only 22:00-06:00 rule. Regression test for a real bug: the
    // wrap branch used to check the CURRENT weekday for both halves of the
    // window, so the post-midnight tail (00:00-06:00) only matched if the
    // NEXT day was also in `days` -- for a Monday-only rule, Tue 02:00
    // silently never matched at all, even though it's still "Monday
    // night" by any normal reading. See QuotesModels.h's -containsWeekday:
    // doc for the full explanation.
    //
    // This test is proven by the fact that reverting -containsWeekday: to
    // the old single-branch form (check `weekday` for both halves) makes
    // testTuesdayZeroTwoHundredMatchesMondayOnlyRule below fail -- it was
    // run against that old code and DID fail there before this fix landed.
    GLQuoteRule *rule = [self filterRuleWithId:@"monday-night" authors:@[] genres:@[] days:@[@2] // Monday only
                                    startMinute:1320 endMinute:360 rotateMinutes:60];

    // Monday evening: still Monday's window, obviously.
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:1320]);  // Mon 22:00
    XCTAssertTrue([rule containsWeekday:2 minuteOfDay:1439]);  // Mon 23:59

    // Tuesday pre-dawn: this is the bug. Belongs to Monday's window even
    // though the calendar day is Tuesday.
    XCTAssertTrue([rule containsWeekday:3 minuteOfDay:0]);     // Tue 00:00
    XCTAssertTrue([rule containsWeekday:3 minuteOfDay:120]);   // Tue 02:00
    XCTAssertTrue([rule containsWeekday:3 minuteOfDay:359]);   // Tue 05:59
    XCTAssertFalse([rule containsWeekday:3 minuteOfDay:360]);  // Tue 06:00 -- window over, exclusive end

    // Tuesday evening is NOT Monday's window -- days only lists Monday, and
    // this is the "before start" half, not the wrapped tail.
    XCTAssertFalse([rule containsWeekday:3 minuteOfDay:1320]); // Tue 22:00

    // Wednesday pre-dawn is TUESDAY's tail, not Monday's -- also not in
    // `days`, so also no match. (Distinguishes this from a bug where the
    // fix over-corrected to "always check the previous day" regardless of
    // whether that previous day's window actually applies.)
    XCTAssertFalse([rule containsWeekday:4 minuteOfDay:120]);  // Wed 02:00
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

#pragma mark - changeDatesFromDate:toDate:... (Stage 2 widget timeline)

- (NSCalendar *)utcCalendar {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    return calendar;
}

- (NSDate *)utcDateYear:(NSInteger)year month:(NSInteger)month day:(NSInteger)day hour:(NSInteger)hour minute:(NSInteger)minute {
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    comps.year = year; comps.month = month; comps.day = day; comps.hour = hour; comps.minute = minute;
    return [[self utcCalendar] dateFromComponents:comps];
}

- (void)testChangeDatesHitEveryRotationBoundaryWithNoRules {
    // No rules at all -> pure default-rotation boundaries. UTC has no DST,
    // so epochMinute%30==0 lines up exactly with :00/:30 local, letting
    // this test assert an EXACT date list rather than just "contains".
    NSDate *start = [self utcDateYear:2026 month:6 day:1 hour:11 minute:45]; // not itself a boundary
    NSDate *end = [self utcDateYear:2026 month:6 day:1 hour:13 minute:15];
    NSArray<NSDate *> *dates = [QuotesRuleEngine changeDatesFromDate:start
                                                                toDate:end
                                                                 rules:@[]
                                                                quotes:@[]
                                                  defaultRotateMinutes:30
                                                              calendar:[self utcCalendar]];
    NSArray<NSDate *> *expected = @[
        [self utcDateYear:2026 month:6 day:1 hour:12 minute:0],
        [self utcDateYear:2026 month:6 day:1 hour:12 minute:30],
        [self utcDateYear:2026 month:6 day:1 hour:13 minute:0],
    ];
    XCTAssertEqualObjects(dates, expected);
}

- (void)testChangeDatesIncludeRuleWindowStartAndEnd {
    NSCalendar *calendar = [self utcCalendar];
    NSDate *start = [self utcDateYear:2026 month:6 day:1 hour:8 minute:50];
    NSDate *end = [self utcDateYear:2026 month:6 day:1 hour:10 minute:10];
    NSInteger weekday = [calendar component:NSCalendarUnitWeekday fromDate:start];
    // 09:00-10:00 window, with its own 120-min rotation so it contributes
    // no extra rotation-grid boundaries of its own inside the window --
    // isolates this test to the window-boundary behaviour specifically.
    GLQuoteRule *rule = [self filterRuleWithId:@"morning" authors:@[] genres:@[] days:@[@(weekday)]
                                    startMinute:540 endMinute:600 rotateMinutes:120];
    NSArray<NSDate *> *dates = [QuotesRuleEngine changeDatesFromDate:start
                                                                toDate:end
                                                                 rules:@[rule]
                                                                quotes:@[]
                                                  defaultRotateMinutes:600 // also no boundary of its own in range
                                                              calendar:calendar];
    XCTAssertTrue([dates containsObject:[self utcDateYear:2026 month:6 day:1 hour:9 minute:0]],
                   @"the rule starting to match is a change even if rotateMinutes didn't hit a grid line");
    XCTAssertTrue([dates containsObject:[self utcDateYear:2026 month:6 day:1 hour:10 minute:0]],
                   @"the rule's window ending (exclusive) is equally a change, back to the default pool");
    XCTAssertEqual(dates.count, 2u, @"nothing else in this range should register a change");
}

- (void)testChangeDatesWithOverlappingRulesFollowFirstMatchPrecedence {
    // rule1 (listed first, so it wins the overlap) covers 09:00-09:30;
    // rule2 covers 09:00-10:00, fully underneath rule1. The identity the
    // engine reports should walk narrow -> wide -> none, matching
    // -selectionForWeekday:...'s documented first-match-wins precedence,
    // not just "whichever rule's own boundary is nearer".
    NSCalendar *calendar = [self utcCalendar];
    NSDate *start = [self utcDateYear:2026 month:6 day:1 hour:8 minute:50];
    NSDate *end = [self utcDateYear:2026 month:6 day:1 hour:10 minute:10];
    NSInteger weekday = [calendar component:NSCalendarUnitWeekday fromDate:start];
    GLQuoteRule *narrow = [self filterRuleWithId:@"narrow" authors:@[] genres:@[] days:@[@(weekday)]
                                      startMinute:540 endMinute:570 rotateMinutes:600];
    GLQuoteRule *wide = [self filterRuleWithId:@"wide" authors:@[] genres:@[] days:@[@(weekday)]
                                    startMinute:540 endMinute:600 rotateMinutes:600];
    NSArray<NSDate *> *dates = [QuotesRuleEngine changeDatesFromDate:start
                                                                toDate:end
                                                                 rules:@[narrow, wide]
                                                                quotes:@[]
                                                  defaultRotateMinutes:600
                                                              calendar:calendar];
    XCTAssertTrue([dates containsObject:[self utcDateYear:2026 month:6 day:1 hour:9 minute:0]], @"none -> narrow");
    XCTAssertTrue([dates containsObject:[self utcDateYear:2026 month:6 day:1 hour:9 minute:30]], @"narrow -> wide, once narrow's window ends");
    XCTAssertTrue([dates containsObject:[self utcDateYear:2026 month:6 day:1 hour:10 minute:0]], @"wide -> none");
}

- (NSCalendar *)newYorkCalendar {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"America/New_York"];
    return calendar;
}

- (void)testChangeDatesAcrossSpringForwardDSTNeverLandsOnTheSkippedHour {
    // 2026-03-08 is a real US spring-forward date: America/New_York jumps
    // from 01:59 straight to 03:00, so no wall-clock 02:xx exists that
    // day. A 60-minute default rotation walked via raw epoch-seconds
    // arithmetic (instead of the calendar-stepping this function actually
    // uses) would either try to materialize an impossible 02:00 local date
    // or silently drift every later boundary by an hour. This proves
    // neither happens: every emitted date is a real local time, and the
    // three real hour-boundaries either side of the gap (01:00, 03:00,
    // 04:00) are exactly what's produced -- no 02:00, and nothing missing.
    NSCalendar *calendar = [self newYorkCalendar];
    NSDateComponents *startComps = [[NSDateComponents alloc] init];
    startComps.year = 2026; startComps.month = 3; startComps.day = 8;
    startComps.hour = 0; startComps.minute = 30;
    NSDate *start = [calendar dateFromComponents:startComps];

    NSDateComponents *endComps = [[NSDateComponents alloc] init];
    endComps.year = 2026; endComps.month = 3; endComps.day = 8;
    endComps.hour = 4; endComps.minute = 30;
    NSDate *end = [calendar dateFromComponents:endComps];

    NSArray<NSDate *> *dates = [QuotesRuleEngine changeDatesFromDate:start
                                                                toDate:end
                                                                 rules:@[]
                                                                quotes:@[]
                                                  defaultRotateMinutes:60
                                                              calendar:calendar];

    NSMutableArray<NSNumber *> *localHours = [NSMutableArray array];
    for (NSDate *date in dates) {
        NSDateComponents *comps = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
        XCTAssertEqual(comps.minute, 0, @"every boundary here should land exactly on the hour: %@", date);
        [localHours addObject:@(comps.hour)];
    }
    XCTAssertEqualObjects(localHours, (@[@1, @3, @4]), @"01:00, then straight to 03:00 (02:00 doesn't exist), then 04:00");
}

@end
