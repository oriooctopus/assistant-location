#import "QuotesRuleEngine.h"

NS_ASSUME_NONNULL_BEGIN

@implementation QuotesSelection

- (instancetype)initWithMatchedRule:(nullable GLQuoteRule *)matchedRule
                                pool:(NSArray<GLQuote *> *)pool
                       rotateMinutes:(NSInteger)rotateMinutes
                awaitingAIResolution:(BOOL)awaitingAIResolution {
    self = [super init];
    if (self) {
        _matchedRule = matchedRule;
        _pool = [pool copy];
        _rotateMinutes = rotateMinutes;
        _awaitingAIResolution = awaitingAIResolution;
    }
    return self;
}

@end

@implementation QuotesRuleEngine

+ (NSArray<GLQuote *> *)poolForRule:(GLQuoteRule *)rule quotes:(NSArray<GLQuote *> *)quotes {
    if ([rule.kind isEqualToString:GLQuoteRuleKindAI]) {
        if (rule.quoteIds.count == 0) return @[];
        NSSet<NSString *> *idSet = [NSSet setWithArray:rule.quoteIds];
        NSMutableArray<GLQuote *> *pool = [NSMutableArray array];
        for (GLQuote *quote in quotes) {
            if ([idSet containsObject:quote.quoteId]) [pool addObject:quote];
        }
        return pool;
    }

    // Filter kind. An unrestricted filter (no authors, no genres listed) is
    // a deliberate "show anything while this window is active" rule -- the
    // alternative (matching nothing) would make a freshly-created rule with
    // no filters picked yet look identical to a rule that legitimately
    // excludes everything, which is worse for a user building up a
    // schedule incrementally.
    if (rule.authors.count == 0 && rule.genres.count == 0) {
        return [quotes copy];
    }
    NSSet<NSString *> *authorSet = [NSSet setWithArray:rule.authors];
    NSSet<NSString *> *genreSet = [NSSet setWithArray:rule.genres];
    NSMutableArray<GLQuote *> *pool = [NSMutableArray array];
    for (GLQuote *quote in quotes) {
        if ([authorSet containsObject:quote.author]) {
            [pool addObject:quote];
            continue;
        }
        for (NSString *genre in quote.genres) {
            if ([genreSet containsObject:genre]) {
                [pool addObject:quote];
                break;
            }
        }
    }
    return pool;
}

+ (QuotesSelection *)selectionForWeekday:(NSInteger)weekday
                              minuteOfDay:(NSInteger)minuteOfDay
                                    rules:(NSArray<GLQuoteRule *> *)rules
                                   quotes:(NSArray<GLQuote *> *)quotes
                     defaultRotateMinutes:(NSInteger)defaultRotateMinutes {
    for (GLQuoteRule *rule in rules) {
        if ([rule containsWeekday:weekday minuteOfDay:minuteOfDay]) {
            NSArray<GLQuote *> *pool = [self poolForRule:rule quotes:quotes];
            BOOL awaitingAI = [rule.kind isEqualToString:GLQuoteRuleKindAI] && rule.quoteIds.count == 0;
            NSInteger rotate = rule.rotateMinutes > 0 ? rule.rotateMinutes : defaultRotateMinutes;
            return [[QuotesSelection alloc] initWithMatchedRule:rule
                                                             pool:pool
                                                    rotateMinutes:rotate
                                             awaitingAIResolution:awaitingAI];
        }
    }
    return [[QuotesSelection alloc] initWithMatchedRule:nil
                                                     pool:[quotes copy]
                                            rotateMinutes:defaultRotateMinutes
                                     awaitingAIResolution:NO];
}

+ (nullable GLQuote *)currentQuoteForSelection:(QuotesSelection *)selection epochMinute:(int64_t)epochMinute {
    NSArray<GLQuote *> *pool = selection.pool;
    if (pool.count == 0) return nil;

    NSInteger rotate = selection.rotateMinutes > 0 ? selection.rotateMinutes : 1;
    int64_t bucket = epochMinute / rotate;
    // C's `%` can return a negative result for a negative left operand
    // (epochMinute is never negative for any real wall-clock date, but a
    // test date before 1970 would take this path) -- normalize into
    // [0, pool.count) rather than indexing with a negative number.
    NSInteger index = (NSInteger)(bucket % (int64_t)pool.count);
    if (index < 0) index += pool.count;
    return pool[index];
}

// Identity of "what's currently selected", cheap to compare minute to
// minute: the matched rule's id, or a sentinel for "no rule matched" (nil
// can't go in an NSString comparison, and we need a value -isEqual:-able).
// Two rules with the same ruleId never both exist (QuotesStore's documents
// don't allow it), so this is a safe proxy for "did the selection change".
static NSString *const kNoRuleSentinel = @"__no_rule__";

+ (NSString *)selectionIdentityForWeekday:(NSInteger)weekday
                               minuteOfDay:(NSInteger)minuteOfDay
                                     rules:(NSArray<GLQuoteRule *> *)rules {
    for (GLQuoteRule *rule in rules) {
        if ([rule containsWeekday:weekday minuteOfDay:minuteOfDay]) return rule.ruleId;
    }
    return kNoRuleSentinel;
}

+ (NSArray<NSDate *> *)changeDatesFromDate:(NSDate *)start
                                     toDate:(NSDate *)end
                                      rules:(NSArray<GLQuoteRule *> *)rules
                                     quotes:(NSArray<GLQuote *> *)quotes
                       defaultRotateMinutes:(NSInteger)defaultRotateMinutes
                                   calendar:(NSCalendar *)calendar {
    if ([end compare:start] != NSOrderedDescending) return @[];

    NSMutableArray<NSDate *> *changeDates = [NSMutableArray array];

    // Walk minute-by-minute via the calendar (never raw
    // timeIntervalSinceReferenceDate += 60) so a 23-hour or 25-hour DST day
    // still visits every WALL-CLOCK minute exactly once, matching how
    // -containsWeekday:minuteOfDay: and a human reading the device's clock
    // both think about "minuteOfDay". `cursor` starts one minute before
    // `start` so the very first candidate (start + 1 minute) has a real
    // "previous identity" to compare against instead of a fabricated one.
    NSDate *cursor = [calendar dateByAddingUnit:NSCalendarUnitMinute value:-1 toDate:start options:0];
    NSDateComponents *cursorComps = [calendar components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
                                                  fromDate:cursor];
    NSString *previousIdentity = [self selectionIdentityForWeekday:cursorComps.weekday
                                                         minuteOfDay:cursorComps.hour * 60 + cursorComps.minute
                                                               rules:rules];

    while (YES) {
        cursor = [calendar dateByAddingUnit:NSCalendarUnitMinute value:1 toDate:cursor options:0];
        if ([cursor compare:end] == NSOrderedDescending) break;

        NSDateComponents *comps = [calendar components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
                                                fromDate:cursor];
        NSInteger weekday = comps.weekday;
        NSInteger minuteOfDay = comps.hour * 60 + comps.minute;
        NSString *identity = [self selectionIdentityForWeekday:weekday minuteOfDay:minuteOfDay rules:rules];

        BOOL ruleBoundary = ![identity isEqualToString:previousIdentity];

        QuotesSelection *selection = [self selectionForWeekday:weekday
                                                     minuteOfDay:minuteOfDay
                                                           rules:rules
                                                          quotes:quotes
                                             defaultRotateMinutes:defaultRotateMinutes];
        NSInteger rotate = selection.rotateMinutes > 0 ? selection.rotateMinutes : 1;
        // Matches QuotesViewController's own epochMinute computation --
        // plain truncation, not floor(); fine since every real wall-clock
        // date is well after 1970 (see -currentQuoteForSelection:'s own
        // comment on the only case where this would matter).
        int64_t epochMinute = (int64_t)(cursor.timeIntervalSince1970 / 60.0);
        BOOL rotationBoundary = (epochMinute % rotate) == 0;

        if (ruleBoundary || rotationBoundary) {
            [changeDates addObject:cursor];
        }
        previousIdentity = identity;
    }

    return [changeDates copy];
}

@end

NS_ASSUME_NONNULL_END
