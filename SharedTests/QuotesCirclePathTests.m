// The Today screen's decorative circle: a pure function date -> grid cell.
// It must be deterministic, move exactly one edge-adjacent cell per day, and
// never sit on a cell the Today layout reserves for text.
#import <XCTest/XCTest.h>
#import "QuotesTheme.h"

@interface QuotesCirclePathTests : XCTestCase
@end

@implementation QuotesCirclePathTests

- (NSCalendar *)calendar {
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneWithName:@"America/Denver"];
    return cal;
}

- (void)testDeterministic {
    NSCalendar *cal = [self calendar];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1760000000];
    QuotesGridCell a = QuotesDecorativeCircleCell(date, cal);
    QuotesGridCell b = QuotesDecorativeCircleCell(date, cal);
    XCTAssertEqual(a.col, b.col);
    XCTAssertEqual(a.row, b.row);
}

- (void)testSameDayDifferentTimeSameCell {
    NSCalendar *cal = [self calendar];
    NSDate *morning = [cal dateWithEra:1 year:2026 month:3 day:9 hour:0 minute:5 second:0 nanosecond:0];
    NSDate *night = [cal dateWithEra:1 year:2026 month:3 day:9 hour:23 minute:55 second:0 nanosecond:0];
    QuotesGridCell a = QuotesDecorativeCircleCell(morning, cal);
    QuotesGridCell b = QuotesDecorativeCircleCell(night, cal);
    XCTAssertEqual(a.col, b.col);
    XCTAssertEqual(a.row, b.row);
}

// Walks 800 consecutive days (spans a year wrap, a leap day and both DST
// changes in America/Denver).
- (void)testOneEdgeAdjacentStepPerDayAndNeverReserved {
    NSCalendar *cal = [self calendar];
    NSDate *day = [cal dateWithEra:1 year:2027 month:12 day:1 hour:12 minute:0 second:0 nanosecond:0];
    QuotesGridCell prev = QuotesDecorativeCircleCell(day, cal);
    XCTAssertFalse(QuotesTodayCellIsReserved(prev));
    for (NSInteger i = 1; i <= 800; i++) {
        day = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0];
        QuotesGridCell cell = QuotesDecorativeCircleCell(day, cal);
        XCTAssertFalse(QuotesTodayCellIsReserved(cell), @"day +%ld landed on reserved cell (%ld,%ld)", (long)i, (long)cell.col, (long)cell.row);
        XCTAssertTrue(cell.col >= 1 && cell.col <= QuotesGridColumns && cell.row >= 1 && cell.row <= QuotesGridRows,
                      @"day +%ld off grid (%ld,%ld)", (long)i, (long)cell.col, (long)cell.row);
        NSInteger step = labs(cell.col - prev.col) + labs(cell.row - prev.row);
        XCTAssertEqual(step, 1, @"day +%ld moved (%ld,%ld) -> (%ld,%ld)", (long)i, (long)prev.col, (long)prev.row, (long)cell.col, (long)cell.row);
        prev = cell;
    }
}

- (void)testVisitsMoreThanOneCell {
    NSCalendar *cal = [self calendar];
    NSDate *day = [cal dateWithEra:1 year:2026 month:1 day:1 hour:12 minute:0 second:0 nanosecond:0];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSInteger i = 0; i < 16; i++) {
        QuotesGridCell c = QuotesDecorativeCircleCell(day, cal);
        [seen addObject:[NSString stringWithFormat:@"%ld,%ld", (long)c.col, (long)c.row]];
        day = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0];
    }
    XCTAssertGreaterThan(seen.count, 4u);
}

@end
