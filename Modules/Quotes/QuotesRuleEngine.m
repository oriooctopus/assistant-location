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

@end

NS_ASSUME_NONNULL_END
