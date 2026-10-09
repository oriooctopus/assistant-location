#import "QuotesModels.h"

NS_ASSUME_NONNULL_BEGIN

NSString *const GLQuoteSourceStock = @"stock";
NSString *const GLQuoteSourceImported = @"imported";

NSString *const GLQuoteRuleKindFilter = @"filter";
NSString *const GLQuoteRuleKindAI = @"ai";

#pragma mark - GLQuote

@implementation GLQuote

- (instancetype)initWithId:(NSString *)quoteId
                       text:(NSString *)text
                     author:(NSString *)author
                     genres:(NSArray<NSString *> *)genres
                     source:(NSString *)source {
    self = [super init];
    if (self) {
        _quoteId = [quoteId copy];
        _text = [text copy];
        _author = [author copy];
        _genres = [genres copy];
        _source = [source copy];
    }
    return self;
}

+ (nullable instancetype)quoteFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = dictionary;
    NSString *quoteId = dict[@"id"];
    NSString *text = dict[@"text"];
    NSString *author = dict[@"author"];
    if (![quoteId isKindOfClass:[NSString class]] || quoteId.length == 0) return nil;
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    if (![author isKindOfClass:[NSString class]] || author.length == 0) return nil;

    NSArray *rawGenres = dict[@"genres"];
    NSMutableArray<NSString *> *genres = [NSMutableArray array];
    if ([rawGenres isKindOfClass:[NSArray class]]) {
        for (id entry in rawGenres) {
            if ([entry isKindOfClass:[NSString class]]) [genres addObject:entry];
        }
    }

    NSString *source = dict[@"source"];
    if (![source isKindOfClass:[NSString class]] || source.length == 0) {
        source = GLQuoteSourceImported; // every caller of this parser today only ever parses imported entries
    }

    return [[self alloc] initWithId:quoteId text:text author:author genres:genres source:source];
}

- (NSDictionary<NSString *, id> *)toDictionary {
    return @{
        @"id": self.quoteId,
        @"text": self.text,
        @"author": self.author,
        @"genres": self.genres,
        @"source": self.source,
    };
}

- (id)copyWithZone:(nullable NSZone *)zone {
    return self; // immutable value object
}

- (BOOL)isEqual:(id)other {
    if (self == other) return YES;
    if (![other isKindOfClass:[GLQuote class]]) return NO;
    GLQuote *o = other;
    return [self.quoteId isEqualToString:o.quoteId];
}

- (NSUInteger)hash {
    return self.quoteId.hash;
}

@end

#pragma mark - GLQuoteRule

@implementation GLQuoteRule

- (instancetype)initWithId:(NSString *)ruleId
                       name:(NSString *)name
                       kind:(NSString *)kind
                    authors:(NSArray<NSString *> *)authors
                     genres:(NSArray<NSString *> *)genres
                     prompt:(NSString *)prompt
                   quoteIds:(NSArray<NSString *> *)quoteIds
                       days:(NSArray<NSNumber *> *)days
                startMinute:(NSInteger)startMinute
                  endMinute:(NSInteger)endMinute
              rotateMinutes:(NSInteger)rotateMinutes {
    self = [super init];
    if (self) {
        _ruleId = [ruleId copy];
        _name = [name copy];
        _kind = [kind copy];
        _authors = [authors copy];
        _genres = [genres copy];
        _prompt = [prompt copy];
        _quoteIds = [quoteIds copy];
        _days = [days copy];
        _startMinute = startMinute;
        _endMinute = endMinute;
        _rotateMinutes = rotateMinutes;
    }
    return self;
}

+ (nullable instancetype)ruleFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = dictionary;
    NSString *ruleId = dict[@"id"];
    if (![ruleId isKindOfClass:[NSString class]] || ruleId.length == 0) return nil;

    NSString *name = [dict[@"name"] isKindOfClass:[NSString class]] ? dict[@"name"] : @"";
    NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : GLQuoteRuleKindFilter;
    if (![kind isEqualToString:GLQuoteRuleKindFilter] && ![kind isEqualToString:GLQuoteRuleKindAI]) {
        kind = GLQuoteRuleKindFilter;
    }
    NSString *prompt = [dict[@"prompt"] isKindOfClass:[NSString class]] ? dict[@"prompt"] : @"";

    NSArray<NSString *> *authors = [self stringArrayFrom:dict[@"authors"]];
    NSArray<NSString *> *genres = [self stringArrayFrom:dict[@"genres"]];
    NSArray<NSString *> *quoteIds = [self stringArrayFrom:dict[@"quoteIds"]];

    NSMutableArray<NSNumber *> *days = [NSMutableArray array];
    if ([dict[@"days"] isKindOfClass:[NSArray class]]) {
        for (id entry in (NSArray *)dict[@"days"]) {
            if ([entry isKindOfClass:[NSNumber class]]) {
                NSInteger day = [(NSNumber *)entry integerValue];
                if (day >= 1 && day <= 7) [days addObject:@(day)];
            }
        }
    }

    NSInteger startMinute = [dict[@"startMinute"] isKindOfClass:[NSNumber class]] ? [dict[@"startMinute"] integerValue] : 0;
    NSInteger endMinute = [dict[@"endMinute"] isKindOfClass:[NSNumber class]] ? [dict[@"endMinute"] integerValue] : 1440;
    NSInteger rotateMinutes = [dict[@"rotateMinutes"] isKindOfClass:[NSNumber class]] ? [dict[@"rotateMinutes"] integerValue] : 60;

    return [[self alloc] initWithId:ruleId
                                name:name
                                kind:kind
                             authors:authors
                              genres:genres
                              prompt:prompt
                            quoteIds:quoteIds
                                days:days
                         startMinute:startMinute
                           endMinute:endMinute
                       rotateMinutes:rotateMinutes];
}

+ (NSArray<NSString *> *)stringArrayFrom:(id)maybeArray {
    if (![maybeArray isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id entry in (NSArray *)maybeArray) {
        if ([entry isKindOfClass:[NSString class]]) [result addObject:entry];
    }
    return result;
}

- (NSDictionary<NSString *, id> *)toDictionary {
    return @{
        @"id": self.ruleId,
        @"name": self.name,
        @"kind": self.kind,
        @"authors": self.authors,
        @"genres": self.genres,
        @"prompt": self.prompt,
        @"quoteIds": self.quoteIds,
        @"days": self.days,
        @"startMinute": @(self.startMinute),
        @"endMinute": @(self.endMinute),
        @"rotateMinutes": @(self.rotateMinutes),
    };
}

- (id)copyWithZone:(nullable NSZone *)zone {
    return [[GLQuoteRule alloc] initWithId:self.ruleId
                                       name:self.name
                                       kind:self.kind
                                    authors:self.authors
                                     genres:self.genres
                                     prompt:self.prompt
                                   quoteIds:self.quoteIds
                                       days:self.days
                                startMinute:self.startMinute
                                  endMinute:self.endMinute
                              rotateMinutes:self.rotateMinutes];
}

- (BOOL)containsWeekday:(NSInteger)weekday minuteOfDay:(NSInteger)minuteOfDay {
    if (self.endMinute == self.startMinute) {
        // Whole-day window, see header doc -- there's no "which day did
        // this start on" ambiguity to resolve, so the simple check is
        // correct as-is.
        return [self.days containsObject:@(weekday)];
    }

    if (self.startMinute < self.endMinute) {
        if (![self.days containsObject:@(weekday)]) return NO;
        return minuteOfDay >= self.startMinute && minuteOfDay < self.endMinute;
    }

    // Wraps past midnight: e.g. start 22:00 (1320), end 06:00 (360). Two
    // separate branches, each checked against the weekday the window
    // actually BELONGS to for that branch -- see header doc for the bug
    // this replaces (both branches used to check `weekday` itself, which
    // made the post-midnight tail require the NEXT day in `days`, not the
    // day the window started on).
    if (minuteOfDay >= self.startMinute) {
        // Before midnight: still `weekday`'s window. No upper bound to
        // check here -- minuteOfDay is always < 1440, and the window runs
        // to midnight on this side.
        return [self.days containsObject:@(weekday)];
    }
    if (minuteOfDay < self.endMinute) {
        // After midnight, still before the window's end: this is
        // YESTERDAY's window (`weekday - 1`, wrapping Sunday=1 back to
        // Saturday=7). A first fix here dropped this upper bound entirely
        // (every minuteOfDay < startMinute fell into this branch), which
        // silently un-did the window's exclusive end for wrapping rules --
        // caught by testMidnightWrapWindowContainsBothSidesOfMidnight
        // failing at exactly minuteOfDay 360/1319/720 in CI run
        // 34871675444.
        NSInteger previousWeekday = (weekday == 1) ? 7 : weekday - 1;
        return [self.days containsObject:@(previousWeekday)];
    }
    // Between endMinute and startMinute: outside the window on both sides.
    return NO;
}

@end

NS_ASSUME_NONNULL_END
