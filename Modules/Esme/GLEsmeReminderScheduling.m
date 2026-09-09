#import "GLEsmeReminderScheduling.h"

NSInteger const GLEsmeReminderWindowStartHour = 11;
NSInteger const GLEsmeReminderWindowEndHour = 21;
NSString *const GLEsmeReminderIdentifierPrefix = @"EsmeDailyCheckin-";

@implementation GLEsmeScheduleEntry

- (instancetype)initWithIdentifier:(NSString *)identifier dateComponents:(NSDateComponents *)dateComponents {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _dateComponents = dateComponents;
    }
    return self;
}

@end

@implementation GLEsmeReminderScheduling

+ (NSString *)identifierForDate:(NSDate *)date calendar:(NSCalendar *)calendar {
    NSDateComponents *ymd = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                         fromDate:date];
    return [NSString stringWithFormat:@"%@%04ld-%02ld-%02ld", GLEsmeReminderIdentifierPrefix,
                                       (long)ymd.year, (long)ymd.month, (long)ymd.day];
}

// The window is [GLEsmeReminderWindowStartHour:00, GLEsmeReminderWindowEndHour:00]
// inclusive of BOTH endpoints -- 21:00 is a valid draw, not an exclusive upper
// bound -- so there are ((end - start) * 60) + 1 equally likely minute-of-day
// offsets from the start hour. randomSource's contract (an upper-EXCLUSIVE
// draw, matching arc4random_uniform) is why the range width passed in is one
// wider than the last valid offset.
+ (NSDateComponents *)dateComponentsForDate:(NSDate *)date
                                    calendar:(NSCalendar *)calendar
                                randomSource:(GLEsmeRandomUpperBoundSource)randomSource {
    NSDateComponents *ymd = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                         fromDate:date];

    NSUInteger windowMinutes = (NSUInteger)((GLEsmeReminderWindowEndHour - GLEsmeReminderWindowStartHour) * 60);
    NSUInteger offsetMinutes = randomSource(windowMinutes + 1);

    NSDateComponents *result = [NSDateComponents new];
    result.year = ymd.year;
    result.month = ymd.month;
    result.day = ymd.day;
    result.hour = GLEsmeReminderWindowStartHour + (NSInteger)(offsetMinutes / 60);
    result.minute = (NSInteger)(offsetMinutes % 60);
    return result;
}

+ (NSArray<GLEsmeScheduleEntry *> *)upcomingScheduleEntriesFromDate:(NSDate *)fromDate
                                                                 days:(NSUInteger)days
                                                             calendar:(NSCalendar *)calendar
                                                         randomSource:(GLEsmeRandomUpperBoundSource)randomSource {
    NSMutableArray<GLEsmeScheduleEntry *> *entries = [NSMutableArray arrayWithCapacity:days];
    for (NSUInteger i = 0; i < days; i++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:(NSInteger)i toDate:fromDate options:0];
        NSString *identifier = [self identifierForDate:day calendar:calendar];
        NSDateComponents *components = [self dateComponentsForDate:day calendar:calendar randomSource:randomSource];
        [entries addObject:[[GLEsmeScheduleEntry alloc] initWithIdentifier:identifier dateComponents:components]];
    }
    return entries;
}

@end
