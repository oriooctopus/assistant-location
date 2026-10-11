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

- (void)testEnabledByDefaultUntilExplicitlyToggledOff {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:@"QuotesDailyNotifyEnabled"];
    XCTAssertTrue([QuotesDailyNotifier isEnabled]);
    [defaults setBool:NO forKey:@"QuotesDailyNotifyEnabled"];
    XCTAssertFalse([QuotesDailyNotifier isEnabled]);
    [defaults removeObjectForKey:@"QuotesDailyNotifyEnabled"];
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

#pragma mark - Save action

- (QuotesDailyEntry *)firstEntry {
    return [self entriesAt:[self dateY:2026 m:10 d:5 h:7] minute:9 * 60 rules:@[] quotes:[self quotes:5]].firstObject;
}

- (void)testContentCarriesCategoryAndQuoteId {
    QuotesDailyEntry *entry = [self firstEntry];
    UNMutableNotificationContent *content = [QuotesDailyNotifier contentForEntry:entry];
    XCTAssertEqualObjects(content.categoryIdentifier, @"quotes-daily");
    XCTAssertEqualObjects(content.userInfo[@"quoteId"], entry.quote.quoteId);
    XCTAssertEqualObjects(content.body, entry.quote.text);
}

- (void)testCategoryHasOneBackgroundSaveAction {
    UNNotificationCategory *category = [QuotesDailyNotifier notificationCategory];
    XCTAssertEqualObjects(category.identifier, @"quotes-daily");
    XCTAssertEqual(category.actions.count, 1u);
    UNNotificationAction *action = category.actions.firstObject;
    XCTAssertEqualObjects(action.identifier, @"quotes-daily-save");
    XCTAssertEqualObjects(action.title, @"Save");
    XCTAssertFalse(action.options & UNNotificationActionOptionForeground, @"saving must not launch the app");
}

- (QuotesStore *)unsignedStore {
    return [[QuotesStore alloc] initWithService:@"com.oliverullman.assistantlocation.quotes.tests"
                                        account:[@"store-" stringByAppendingString:[NSUUID UUID].UUIDString]
                                    accessGroup:nil];
}

- (void)testSaveActionWritesToTheStore {
    // The unsigned CI keychain rejects every write, so a failed save with the
    // store's own error domain is the proof the action reached
    // -[QuotesStore setQuoteId:saved:error:] (the round trip itself is in
    // QuotesStoreTests, signed hosts only).
    NSError *error = nil;
    BOOL ok = [QuotesDailyNotifier handleActionIdentifier:QuotesDailySaveActionIdentifier
                                                 userInfo:@{@"quoteId": @"q1"}
                                                    store:[self unsignedStore] error:&error];
    XCTAssertFalse(ok);
    XCTAssertEqualObjects(error.domain, QuotesStoreErrorDomain);
}

- (void)testOtherActionsDoNothing {
    NSError *error = nil;
    BOOL ok = [QuotesDailyNotifier handleActionIdentifier:UNNotificationDefaultActionIdentifier
                                                 userInfo:@{@"quoteId": @"q1"}
                                                    store:[self unsignedStore] error:&error];
    XCTAssertFalse(ok);
    XCTAssertNil(error, @"a non-save action never touches the store");
}

- (void)testBodyTapOpensTheNotifiedQuote {
    XCTAssertEqualObjects([QuotesDailyNotifier quoteIdToOpenForActionIdentifier:UNNotificationDefaultActionIdentifier
                                                                       userInfo:@{@"quoteId": @"q1"}], @"q1");
}

- (void)testSaveAndDismissOpenNothing {
    XCTAssertNil([QuotesDailyNotifier quoteIdToOpenForActionIdentifier:QuotesDailySaveActionIdentifier
                                                              userInfo:@{@"quoteId": @"q1"}]);
    XCTAssertNil([QuotesDailyNotifier quoteIdToOpenForActionIdentifier:UNNotificationDismissActionIdentifier
                                                              userInfo:@{@"quoteId": @"q1"}]);
}

- (void)testBodyTapWithoutQuoteIdRaises {
    XCTAssertThrows([QuotesDailyNotifier quoteIdToOpenForActionIdentifier:UNNotificationDefaultActionIdentifier userInfo:@{}]);
}

- (void)testSaveActionWithoutQuoteIdRaises {
    XCTAssertThrows([QuotesDailyNotifier handleActionIdentifier:QuotesDailySaveActionIdentifier
                                                       userInfo:@{}
                                                          store:[self unsignedStore] error:NULL]);
}

#pragma mark - History

- (NSDictionary *)sched:(NSString *)date fireY:(NSInteger)y m:(NSInteger)m d:(NSInteger)d text:(NSString *)text {
    NSDate *fire = [self dateY:y m:m d:d h:9];
    return @{@"date": date, @"fire": @(fire.timeIntervalSince1970), @"quoteId": [@"id-" stringByAppendingString:date], @"text": text, @"author": @"A"};
}

- (void)testHistoryMovesPastDueEntriesAndKeepsFutureOnes {
    NSDate *now = [self dateY:2026 m:10 d:11 h:12];
    NSArray *scheduled = @[[self sched:@"2026-10-10" fireY:2026 m:10 d:10 text:@"t10"],
                           [self sched:@"2026-10-11" fireY:2026 m:10 d:11 text:@"t11"],
                           [self sched:@"2026-10-12" fireY:2026 m:10 d:12 text:@"t12"]];
    NSArray *h = [QuotesDailyNotifier historyByMergingScheduled:scheduled intoHistory:@[] now:now];
    XCTAssertEqual(h.count, 2u);
    XCTAssertEqualObjects(h[0][@"date"], @"2026-10-11");
    XCTAssertEqualObjects(h[1][@"date"], @"2026-10-10");
}

- (void)testHistoryFireTimeExactlyNowCountsAsFired {
    NSDate *now = [self dateY:2026 m:10 d:11 h:9];
    NSArray *h = [QuotesDailyNotifier historyByMergingScheduled:@[[self sched:@"2026-10-11" fireY:2026 m:10 d:11 text:@"t"]] intoHistory:@[] now:now];
    XCTAssertEqual(h.count, 1u);
}

- (void)testHistoryDedupesByDateFirstRecordedWins {
    NSDate *now = [self dateY:2026 m:10 d:12 h:12];
    NSArray *existing = @[[self sched:@"2026-10-10" fireY:2026 m:10 d:10 text:@"first"]];
    NSArray *scheduled = @[[self sched:@"2026-10-10" fireY:2026 m:10 d:10 text:@"second"],
                           [self sched:@"2026-10-11" fireY:2026 m:10 d:11 text:@"t11"]];
    NSArray *h = [QuotesDailyNotifier historyByMergingScheduled:scheduled intoHistory:existing now:now];
    XCTAssertEqual(h.count, 2u);
    XCTAssertEqualObjects(h[1][@"text"], @"first");
}

- (void)testHistoryIsNewestFirstAndKeepsSnapshotText {
    NSDate *now = [self dateY:2026 m:10 d:20 h:12];
    NSArray *existing = @[[self sched:@"2026-10-05" fireY:2026 m:10 d:5 text:@"old"]];
    NSArray *scheduled = @[[self sched:@"2026-10-08" fireY:2026 m:10 d:8 text:@"snap8"],
                           [self sched:@"2026-10-15" fireY:2026 m:10 d:15 text:@"snap15"]];
    NSArray *h = [QuotesDailyNotifier historyByMergingScheduled:scheduled intoHistory:existing now:now];
    XCTAssertEqualObjects([h valueForKey:@"date"], (@[@"2026-10-15", @"2026-10-08", @"2026-10-05"]));
    XCTAssertEqualObjects(h[0][@"text"], @"snap15");
    XCTAssertEqualObjects(h[0][@"author"], @"A");
}

- (void)testHistoryCapsAt365DroppingOldest {
    NSMutableArray *existing = [NSMutableArray array];
    for (NSInteger i = 0; i < 365; i++) {
        NSString *date = [NSString stringWithFormat:@"2025-%02ld-%02ld", (long)(i / 28) + 1, (long)(i % 28) + 1];
        [existing addObject:@{@"date": date, @"fire": @0, @"quoteId": @"x", @"text": @"t", @"author": @"A"}];
    }
    NSDate *now = [self dateY:2026 m:10 d:20 h:12];
    NSArray *h = [QuotesDailyNotifier historyByMergingScheduled:@[[self sched:@"2026-10-15" fireY:2026 m:10 d:15 text:@"new"]] intoHistory:existing now:now];
    XCTAssertEqual(h.count, 365u);
    XCTAssertEqualObjects(h[0][@"date"], @"2026-10-15");
    XCTAssertEqualObjects([h.lastObject objectForKey:@"date"], @"2025-01-02", @"oldest entry (2025-01-01) is dropped");
}

@end
