// Pure scheduling logic of QuotesDailyNotifier: which days get a request,
// at what time, with which quote. No notification center involved.
#import <XCTest/XCTest.h>
#import "QuotesDailyNotifier.h"
#import "QuotesModels.h"

@interface QuotesDailyNotifierTests : XCTestCase
@property(nonatomic, strong) NSCalendar *calendar;
@end

@implementation QuotesDailyNotifierTests

- (void)setUp {
    self.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    self.calendar.timeZone = [NSTimeZone timeZoneWithName:@"America/New_York"];
}

- (NSDate *)dateY:(NSInteger)y m:(NSInteger)m d:(NSInteger)d h:(NSInteger)h {
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.year = y; c.month = m; c.day = d; c.hour = h;
    return [self.calendar dateFromComponents:c];
}

- (NSArray<GLQuote *> *)quotes:(NSInteger)n {
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        [out addObject:[[GLQuote alloc] initWithId:[NSString stringWithFormat:@"q%ld", (long)i]
                                               text:[NSString stringWithFormat:@"text %ld", (long)i]
                                             author:@"A" genres:@[] source:GLQuoteSourceStock]];
    }
    return out;
}

- (NSArray<QuotesDailyEntry *> *)entriesAt:(NSDate *)now minute:(NSInteger)minute rules:(NSArray<GLQuoteRule *> *)rules quotes:(NSArray<GLQuote *> *)quotes {
    return [QuotesDailyNotifier entriesFromDate:now daysAhead:14 minuteOfDay:minute rules:rules quotes:quotes
                           defaultRotateMinutes:60 calendar:self.calendar];
}

- (void)testSchedulesFourteenDaysWhenTodaysTimeIsStillAhead {
    NSArray *entries = [self entriesAt:[self dateY:2026 m:10 d:5 h:7] minute:9 * 60 rules:@[] quotes:[self quotes:30]];
    XCTAssertEqual(entries.count, 14u);
    QuotesDailyEntry *first = entries.firstObject;
    XCTAssertEqualObjects(first.identifier, @"quotes-daily-2026-10-05");
    XCTAssertEqual(first.dateComponents.hour, 9);
    XCTAssertEqual(first.dateComponents.minute, 0);
}

- (void)testSkipsTodayWhenFireTimeAlreadyPassed {
    NSArray *entries = [self entriesAt:[self dateY:2026 m:10 d:5 h:10] minute:9 * 60 rules:@[] quotes:[self quotes:30]];
    XCTAssertEqual(entries.count, 13u);
    XCTAssertEqualObjects(((QuotesDailyEntry *)entries.firstObject).identifier, @"quotes-daily-2026-10-06");
}

- (void)testConsecutiveDaysGetDifferentQuotes {
    NSArray<QuotesDailyEntry *> *entries = [self entriesAt:[self dateY:2026 m:10 d:5 h:7] minute:9 * 60 rules:@[] quotes:[self quotes:30]];
    NSSet *ids = [NSSet setWithArray:[entries valueForKeyPath:@"quote.quoteId"]];
    XCTAssertEqual(ids.count, 14u);
}

- (void)testRuleMatchingFireTimeRestrictsPoolAndEmptyPoolSkipsDay {
    GLQuote *a = [[GLQuote alloc] initWithId:@"a" text:@"ta" author:@"Seneca" genres:@[] source:GLQuoteSourceStock];
    GLQuote *b = [[GLQuote alloc] initWithId:@"b" text:@"tb" author:@"Other" genres:@[] source:GLQuoteSourceStock];
    // Mondays (weekday 2) only, 08:00-10:00, Seneca only.
    GLQuoteRule *rule = [[GLQuoteRule alloc] initWithId:@"r" name:@"r" kind:GLQuoteRuleKindFilter authors:@[@"Seneca"] genres:@[]
                                                  prompt:@"" quoteIds:@[] days:@[@2] startMinute:480 endMinute:600 rotateMinutes:60];
    // 2026-10-05 is a Monday.
    NSArray<QuotesDailyEntry *> *entries = [self entriesAt:[self dateY:2026 m:10 d:5 h:7] minute:9 * 60 rules:@[rule] quotes:@[a, b]];
    XCTAssertEqualObjects(((QuotesDailyEntry *)entries.firstObject).quote.quoteId, @"a");
    // Non-Mondays fall back to every quote, so both appear across the window.
    NSSet *ids = [NSSet setWithArray:[entries valueForKeyPath:@"quote.quoteId"]];
    XCTAssertTrue([ids containsObject:@"b"]);

    // AI rule with no resolved quoteIds => empty pool => Monday has no entry.
    GLQuoteRule *ai = [[GLQuoteRule alloc] initWithId:@"ai" name:@"ai" kind:GLQuoteRuleKindAI authors:@[] genres:@[]
                                                prompt:@"calm" quoteIds:@[] days:@[@2] startMinute:480 endMinute:600 rotateMinutes:60];
    NSArray<QuotesDailyEntry *> *skipped = [self entriesAt:[self dateY:2026 m:10 d:5 h:7] minute:9 * 60 rules:@[ai] quotes:@[a, b]];
    XCTAssertEqualObjects(((QuotesDailyEntry *)skipped.firstObject).identifier, @"quotes-daily-2026-10-06");
}

@end
