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

@end

@implementation AutoJournalStaleGuard {
    NSUInteger _latest;
}

- (NSUInteger)begin { return ++_latest; }
- (BOOL)isCurrent:(NSUInteger)token { return token == _latest; }
- (void)invalidate { _latest++; }

@end
