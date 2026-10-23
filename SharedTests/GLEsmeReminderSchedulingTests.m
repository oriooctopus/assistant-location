// Regression coverage for the Esme daily check-in's move from a fixed 21:00
// repeating trigger to a random-time-per-day scheme. Pure logic, no
// UNUserNotificationCenter, no simulator -- see GLEsmeReminderScheduling.h's
// header comment for why this split exists.
#import <XCTest/XCTest.h>
#import "GLEsmeReminderScheduling.h"

@interface GLEsmeReminderSchedulingTests : XCTestCase
@end

@implementation GLEsmeReminderSchedulingTests

- (NSCalendar *)utcCalendar {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    return calendar;
}

// arc4random_uniform's real contract: uniform over [0, upperBound). A
// sequential source (0, 1, 2, ...) is enough to prove the WINDOW MATH is
// right (every offset it's fed maps into 11:00-21:00), independent of
// whether the app's real randomness is uniform.
- (GLEsmeRandomUpperBoundSource)sequentialSourceStartingAt:(NSUInteger)start {
    __block NSUInteger next = start;
    return ^NSUInteger(NSUInteger upperBound) {
        NSUInteger value = next % upperBound;
        next++;
        return value;
    };
}

// Real, non-deterministic randomness -- what the app actually wires up in
// EsmeModule.m -- for tests that need to see real variance across many
// independent draws.
- (GLEsmeRandomUpperBoundSource)realRandomSource {
    return ^NSUInteger(NSUInteger upperBound) {
        return (NSUInteger)arc4random_uniform((uint32_t)upperBound);
    };
}

// Every generated time must fall within [11:00, 21:00] -- BOTH endpoints
// inclusive (an offset of exactly 0 minutes must produce 11:00 and an offset
// of exactly the window's full width must produce 21:00, not 20:59). Runs
// across many iterations with real randomness, plus the boundary offsets
// explicitly via the sequential source.
- (void)testEveryGeneratedTimeFallsWithinTheWindowInclusiveOfBothBounds {
    NSCalendar *calendar = [self utcCalendar];
    NSDate *day = [calendar dateFromComponents:({
        NSDateComponents *c = [NSDateComponents new];
        c.year = 2026; c.month = 3; c.day = 10;
        c;
    })];

    for (NSInteger i = 0; i < 500; i++) {
        NSDateComponents *components = [GLEsmeReminderScheduling dateComponentsForDate:day
                                                                                calendar:calendar
                                                                            randomSource:[self realRandomSource]];
        XCTAssertGreaterThanOrEqual(components.hour, GLEsmeReminderWindowStartHour);
        if (components.hour == GLEsmeReminderWindowEndHour) {
            XCTAssertEqual(components.minute, 0, @"21:00 is the last valid minute, not 21:01+");
        } else {
            XCTAssertLessThan(components.hour, GLEsmeReminderWindowEndHour);
        }
        XCTAssertGreaterThanOrEqual(components.minute, 0);
        XCTAssertLessThan(components.minute, 60);
    }

    // Explicit boundary offsets: offset 0 -> exactly 11:00, offset
    // (windowHours*60) -> exactly 21:00.
    NSUInteger windowMinutes = (NSUInteger)((GLEsmeReminderWindowEndHour - GLEsmeReminderWindowStartHour) * 60);

    NSDateComponents *lowerBound = [GLEsmeReminderScheduling dateComponentsForDate:day
                                                                            calendar:calendar
                                                                        randomSource:^NSUInteger(NSUInteger upperBound) {
        return 0;
    }];
    XCTAssertEqual(lowerBound.hour, GLEsmeReminderWindowStartHour);
    XCTAssertEqual(lowerBound.minute, 0);

    NSDateComponents *upperBoundComponents = [GLEsmeReminderScheduling dateComponentsForDate:day
                                                                                      calendar:calendar
                                                                                  randomSource:^NSUInteger(NSUInteger upperBound) {
        return upperBound - 1; // the maximum value randomSource can return
    }];
    XCTAssertEqual(upperBoundComponents.hour, GLEsmeReminderWindowEndHour);
    XCTAssertEqual(upperBoundComponents.minute, 0);
    (void)windowMinutes;
}

// The whole point of this change: times must actually VARY from day to day.
// A broken implementation that returns a constant time must fail this test
// -- asserted by counting DISTINCT (hour, minute) pairs across a real
// 14-day schedule, not merely checking "it returned something".
- (void)testTimesVaryAcrossUpcomingDays {
    NSCalendar *calendar = [self utcCalendar];
    NSDate *today = [calendar dateFromComponents:({
        NSDateComponents *c = [NSDateComponents new];
        c.year = 2026; c.month = 3; c.day = 10;
        c;
    })];

    NSArray<GLEsmeScheduleEntry *> *entries =
        [GLEsmeReminderScheduling upcomingScheduleEntriesFromDate:today
                                                               days:14
                                                           calendar:calendar
                                                       randomSource:[self realRandomSource]];
    XCTAssertEqual(entries.count, 14u);

    NSMutableSet<NSString *> *distinctTimes = [NSMutableSet set];
    for (GLEsmeScheduleEntry *entry in entries) {
        [distinctTimes addObject:[NSString stringWithFormat:@"%ld:%02ld",
                                   (long)entry.dateComponents.hour, (long)entry.dateComponents.minute]];
    }

    // With a 601-value window and only 14 independent draws, a coincidental
    // exact repeat isn't impossible, but a healthy random source should
    // produce well over half distinct values; this is the assertion that
    // must go RED against a constant-returning generator (see report: this
    // check was proven to fail by temporarily hardcoding the source to
    // always return 0).
    XCTAssertGreaterThan(distinctTimes.count, 7u,
                          @"expected most of 14 independently-random days to land at different times, got %lu distinct times",
                          (unsigned long)distinctTimes.count);
}

- (void)testIdentifiersAreTheDeterministicPerDayForm {
    NSCalendar *calendar = [self utcCalendar];
    NSDate *date = [calendar dateFromComponents:({
        NSDateComponents *c = [NSDateComponents new];
        c.year = 2026; c.month = 3; c.day = 9;
        c;
    })];

    NSString *identifier = [GLEsmeReminderScheduling identifierForDate:date calendar:calendar];
    XCTAssertEqualObjects(identifier, @"EsmeDailyCheckin-2026-03-09");
    XCTAssertTrue([identifier hasPrefix:GLEsmeReminderIdentifierPrefix]);
}

// Single-digit month/day must still zero-pad -- a naive %ld would produce
// "EsmeDailyCheckin-2026-3-9" instead of "...-03-09", which would silently
// break both string equality against a later re-run AND lexical sorting.
- (void)testIdentifierZeroPadsSingleDigitMonthAndDay {
    NSCalendar *calendar = [self utcCalendar];
    NSDate *date = [calendar dateFromComponents:({
        NSDateComponents *c = [NSDateComponents new];
        c.year = 2026; c.month = 1; c.day = 5;
        c;
    })];

    NSString *identifier = [GLEsmeReminderScheduling identifierForDate:date calendar:calendar];
    XCTAssertEqualObjects(identifier, @"EsmeDailyCheckin-2026-01-05");
}

// Re-running scheduling for the exact same set of days must produce the
// exact same set of identifiers -- this is what lets EsmeModule.m recognize
// "day N is already pending" and skip re-adding (and re-randomizing) it, the
// idempotency property the batch scheme needs in place of the old single
// fixed identifier's natural dedup.
- (void)testRerunningForTheSameDatesProducesIdenticalIdentifiers {
    NSCalendar *calendar = [self utcCalendar];
    NSDate *today = [calendar dateFromComponents:({
        NSDateComponents *c = [NSDateComponents new];
        c.year = 2026; c.month = 3; c.day = 10;
        c;
    })];

    NSArray<GLEsmeScheduleEntry *> *first =
        [GLEsmeReminderScheduling upcomingScheduleEntriesFromDate:today
                                                               days:14
                                                           calendar:calendar
                                                       randomSource:[self realRandomSource]];
    NSArray<GLEsmeScheduleEntry *> *second =
        [GLEsmeReminderScheduling upcomingScheduleEntriesFromDate:today
                                                               days:14
                                                           calendar:calendar
                                                       randomSource:[self realRandomSource]];

    NSArray<NSString *> *firstIdentifiers = [first valueForKey:@"identifier"];
    NSArray<NSString *> *secondIdentifiers = [second valueForKey:@"identifier"];
    XCTAssertEqualObjects(firstIdentifiers, secondIdentifiers);

    // No duplicate identifiers WITHIN one 14-day batch either -- one entry
    // per calendar day.
    XCTAssertEqual([NSSet setWithArray:firstIdentifiers].count, first.count);
}

// Tap routing: only this module's own reminders open the check-in, so a tap
// on a GLManager send-failure alert or an APNs push doesn't hijack the tab.
- (void)testIsReminderIdentifierMatchesOnlyEsmeReminders {
    NSString *dated = [GLEsmeReminderScheduling identifierForDate:[NSDate date] calendar:[self utcCalendar]];
    XCTAssertTrue([GLEsmeReminderScheduling isReminderIdentifier:dated]);
    XCTAssertTrue([GLEsmeReminderScheduling isReminderIdentifier:@"EsmeDailyCheckinReminder"]);
    XCTAssertFalse([GLEsmeReminderScheduling isReminderIdentifier:@"8F2C1A9E-3B4D-4E5F-9A0B-1C2D3E4F5A6B"]);
    XCTAssertFalse([GLEsmeReminderScheduling isReminderIdentifier:@""]);
}

// --- Nag regression: scheduled-through / completed-day filtering ---

- (NSArray<GLEsmeScheduleEntry *> *)entriesFrom:(NSString *)startKey days:(NSUInteger)days {
    NSCalendar *calendar = [self utcCalendar];
    NSDateFormatter *f = [NSDateFormatter new];
    f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = @"yyyy-MM-dd";
    return [GLEsmeReminderScheduling upcomingScheduleEntriesFromDate:[f dateFromString:startKey]
                                                                days:days
                                                            calendar:calendar
                                                        randomSource:[self realRandomSource]];
}

- (NSArray<NSString *> *)keysOf:(NSArray<GLEsmeScheduleEntry *> *)entries {
    NSMutableArray *keys = [NSMutableArray array];
    for (GLEsmeScheduleEntry *e in entries) [keys addObject:[GLEsmeReminderScheduling dayKeyForIdentifier:e.identifier]];
    return keys;
}

// Bug 2: today's reminder fired, so it left the pending list; the next
// foreground top-up must NOT re-add it at a new random time.
- (void)testFiredTodayIsNotReAdded {
    NSArray *entries = [self entriesFrom:@"2026-03-10" days:5]; // 10..14
    // Pending now holds only 11..14 (the 10th fired). Nothing stored (old install).
    NSArray *pending = @[@"EsmeDailyCheckin-2026-03-11", @"EsmeDailyCheckin-2026-03-12",
                         @"EsmeDailyCheckin-2026-03-13", @"EsmeDailyCheckin-2026-03-14"];
    NSString *through = [GLEsmeReminderScheduling scheduledThroughDayKeyWithStored:nil pendingIdentifiers:pending];
    XCTAssertEqualObjects(through, @"2026-03-14");
    NSArray *toAdd = [GLEsmeReminderScheduling entriesToScheduleFrom:entries scheduledThrough:through];
    XCTAssertEqual(toAdd.count, 0u, @"fired day 03-10 must not be re-added, got %@", [self keysOf:toAdd]);
}

// Same, when the fired day was the ONLY pending one and a stored value exists.
- (void)testStoredThroughBlocksReAddWhenPendingIsEmpty {
    NSArray *entries = [self entriesFrom:@"2026-03-10" days:3];
    NSString *through = [GLEsmeReminderScheduling scheduledThroughDayKeyWithStored:@"2026-03-12" pendingIdentifiers:@[]];
    XCTAssertEqualObjects(through, @"2026-03-12");
    XCTAssertEqual([GLEsmeReminderScheduling entriesToScheduleFrom:entries scheduledThrough:through].count, 0u);
}

// Migration: no stored value and no pending Esme ids -> schedule everything;
// the old fixed identifier and foreign ids are ignored for the max.
- (void)testMigrationUsesPendingMaxAndIgnoresForeignIdentifiers {
    XCTAssertNil([GLEsmeReminderScheduling scheduledThroughDayKeyWithStored:nil pendingIdentifiers:@[]]);
    NSString *through = [GLEsmeReminderScheduling scheduledThroughDayKeyWithStored:nil
        pendingIdentifiers:@[@"EsmeDailyCheckinReminder", @"some-uuid", @"EsmeDailyCheckin-2026-03-12", @"EsmeDailyCheckin-2026-03-11"]];
    XCTAssertEqualObjects(through, @"2026-03-12");
    // A stored value later than every pending id wins.
    XCTAssertEqualObjects([GLEsmeReminderScheduling scheduledThroughDayKeyWithStored:@"2026-03-20"
        pendingIdentifiers:@[@"EsmeDailyCheckin-2026-03-12"]], @"2026-03-20");
    XCTAssertEqual([GLEsmeReminderScheduling entriesToScheduleFrom:[self entriesFrom:@"2026-03-10" days:4] scheduledThrough:nil].count, 4u);
}

// Days after scheduledThrough are still scheduled (window top-up works).
- (void)testDaysAfterThroughStillScheduled {
    NSArray *entries = [self entriesFrom:@"2026-03-10" days:6]; // 10..15
    NSArray *toAdd = [GLEsmeReminderScheduling entriesToScheduleFrom:entries scheduledThrough:@"2026-03-12"];
    XCTAssertEqualObjects([self keysOf:toAdd], (@[@"2026-03-13", @"2026-03-14", @"2026-03-15"]));
}

- (void)testIsValidDayKey {
    XCTAssertTrue([GLEsmeReminderScheduling isValidDayKey:@"2026-03-09"]);
    XCTAssertFalse([GLEsmeReminderScheduling isValidDayKey:@"2026-3-9"]);
    XCTAssertFalse([GLEsmeReminderScheduling isValidDayKey:@"2026-03-09x"]);
    XCTAssertFalse([GLEsmeReminderScheduling isValidDayKey:@"x2026-03-09"]);
    XCTAssertFalse([GLEsmeReminderScheduling isValidDayKey:@""]);
}

@end
