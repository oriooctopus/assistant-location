#import "AutoJournalLiveText.h"

@implementation AutoJournalLiveText

+ (NSString *)joinCommitted:(NSString *)committed partial:(NSString *)partial {
    if (committed.length == 0) return partial;
    if (partial.length == 0) return committed;
    return [NSString stringWithFormat:@"%@ %@", committed, partial];
}

+ (NSString *)tailOfText:(NSString *)text maxCharacters:(NSUInteger)maxCharacters {
    if (text.length <= maxCharacters) return text;
    NSUInteger start = text.length - maxCharacters;
    // Never begin mid-word: if the cut lands inside one, skip forward past its remaining letters.
    if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:start - 1]] &&
        ![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:start]]) {
        NSRange space = [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
                                              options:0
                                                range:NSMakeRange(start, text.length - start)];
        if (space.location != NSNotFound) start = space.location + 1;
    }
    NSString *tail = [[text substringFromIndex:start] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [@"…" stringByAppendingString:tail];
}

+ (CGFloat)levelForDecibels:(float)decibels floorDb:(float)floorDb {
    if (decibels <= floorDb) return 0;
    if (decibels >= 0) return 1;
    return (decibels - floorDb) / (0 - floorDb);
}

+ (NSString *)summaryLineForTitle:(NSString *)title tweet:(BOOL)tweet esme:(BOOL)esme {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:trimmed.length ? trimmed : @"Title (optional)"];
    if (tweet) [parts addObject:@"Tweet"];
    if (esme) [parts addObject:@"Esme"];
    return [parts componentsJoinedByString:@" \u00B7 "];
}

+ (NSArray<NSNumber *> *)decibelListFromString:(NSString *)csv {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSString *part in [csv componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSScanner *scanner = [NSScanner scannerWithString:t];
        float value;
        if (t.length > 0 && [scanner scanFloat:&value] && scanner.isAtEnd) [out addObject:@(value)];
    }
    return out;
}

@end

@implementation AutoJournalLevelBuffer {
    NSMutableArray<NSNumber *> *_levels;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _capacity = capacity;
        [self clear];
    }
    return self;
}

- (void)clear {
    _levels = [NSMutableArray arrayWithCapacity:_capacity];
    for (NSUInteger i = 0; i < _capacity; i++) [_levels addObject:@0];
}

- (void)push:(CGFloat)level {
    [_levels removeObjectAtIndex:0];
    [_levels addObject:@(MAX(0, MIN(1, level)))];
}

- (NSArray<NSNumber *> *)levels { return [_levels copy]; }

@end

@implementation AutoJournalStaleGuard {
    NSUInteger _latest;
}

- (NSUInteger)begin { return ++_latest; }
- (BOOL)isCurrent:(NSUInteger)token { return token == _latest; }
- (void)invalidate { _latest++; }

@end
