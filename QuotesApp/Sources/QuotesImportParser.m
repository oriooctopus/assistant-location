#import "QuotesImportParser.h"

NS_ASSUME_NONNULL_BEGIN

@implementation QuotesParsedQuote

- (instancetype)initWithText:(NSString *)text author:(NSString *)author {
    self = [super init];
    if (self) {
        _text = [text copy];
        _author = [author copy];
    }
    return self;
}

@end

@implementation QuotesImportParser

+ (NSString *)stripSurroundingQuotes:(NSString *)text {
    NSString *result = text;
    NSCharacterSet *openQuotes = [NSCharacterSet characterSetWithCharactersInString:@"\"'“‘"];
    NSCharacterSet *closeQuotes = [NSCharacterSet characterSetWithCharactersInString:@"\"'”’"];
    if (result.length >= 2
        && [openQuotes characterIsMember:[result characterAtIndex:0]]
        && [closeQuotes characterIsMember:[result characterAtIndex:result.length - 1]]) {
        result = [result substringWithRange:NSMakeRange(1, result.length - 2)];
    }
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (QuotesParsedQuote *)parseOneEntry:(NSString *)entry {
    NSString *trimmed = [entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return [[QuotesParsedQuote alloc] initWithText:@"" author:@"Unknown"];

    // Greedy .* on the text side so the split lands on the LAST
    // whitespace-bounded dash/tilde in the line, not the first -- text
    // containing an internal hyphenated word ("well-known", with no
    // surrounding whitespace) never matches this separator at all, but a
    // quote containing an em dash of its own ("Fear is the mind-killer —
    // I will not fear" — Author) still splits at the real, trailing
    // attribution separator.
    static NSRegularExpression *dashRegex;
    static dispatch_once_t dashToken;
    dispatch_once(&dashToken, ^{
        dashRegex = [NSRegularExpression regularExpressionWithPattern:@"^(.*)\\s+[-\\x{2013}\\x{2014}~]\\s+(.+)$"
                                                                options:0
                                                                  error:nil];
    });
    NSTextCheckingResult *match = [dashRegex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (match != nil && match.numberOfRanges == 3) {
        NSString *textPart = [self stripSurroundingQuotes:[trimmed substringWithRange:[match rangeAtIndex:1]]];
        NSString *authorPart = [[trimmed substringWithRange:[match rangeAtIndex:2]]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (textPart.length > 0) {
            return [[QuotesParsedQuote alloc] initWithText:textPart author:authorPart.length > 0 ? authorPart : @"Unknown"];
        }
    }

    // CSV `text,author` -- only tried when the dash form above found
    // nothing, and only for exactly one comma (more than one is ambiguous
    // with no quoting convention to resolve it, so it falls through to the
    // whole-line case below instead of guessing which comma is the split).
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@","];
    if (parts.count == 2) {
        NSString *textPart = [self stripSurroundingQuotes:
            [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        NSString *authorPart = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (textPart.length > 0) {
            return [[QuotesParsedQuote alloc] initWithText:textPart author:authorPart.length > 0 ? authorPart : @"Unknown"];
        }
    }

    NSString *whole = [self stripSurroundingQuotes:trimmed];
    return [[QuotesParsedQuote alloc] initWithText:whole author:@"Unknown"];
}

+ (NSArray<NSString *> *)blockSplit:(NSString *)input {
    // componentsSeparatedByString:@"\n\n" only catches an EXACT double
    // newline; a real paste can carry "\n \n" (whitespace on the blank
    // line) or three-plus consecutive newlines, so blank-line detection
    // goes through this regex instead.
    static NSRegularExpression *blankLineRegex;
    static dispatch_once_t blankToken;
    dispatch_once(&blankToken, ^{
        blankLineRegex = [NSRegularExpression regularExpressionWithPattern:@"\\n[ \\t]*\\n+" options:0 error:nil];
    });
    NSArray<NSTextCheckingResult *> *matches = [blankLineRegex matchesInString:input options:0 range:NSMakeRange(0, input.length)];
    if (matches.count == 0) return @[input];

    NSMutableArray<NSString *> *blocks = [NSMutableArray array];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *m in matches) {
        [blocks addObject:[input substringWithRange:NSMakeRange(cursor, m.range.location - cursor)]];
        cursor = m.range.location + m.range.length;
    }
    [blocks addObject:[input substringFromIndex:cursor]];
    return blocks;
}

+ (NSArray<QuotesParsedQuote *> *)parseText:(NSString *)input {
    NSMutableArray<QuotesParsedQuote *> *results = [NSMutableArray array];
    if (input.length == 0) return results;

    NSArray<NSString *> *blocks = [self blockSplit:input];
    NSMutableArray<NSString *> *entries = [NSMutableArray array];

    if (blocks.count > 1) {
        // Blank-line-block mode: one entry per block, its internal
        // newlines collapsed to spaces so a quote wrapped across lines in
        // the paste survives as one entry.
        for (NSString *block in blocks) {
            NSArray<NSString *> *lines = [block componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSString *joined = [lines componentsJoinedByString:@" "];
            NSString *trimmedBlock = [joined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmedBlock.length > 0) [entries addObject:trimmedBlock];
        }
    } else {
        // No blank lines anywhere in the paste -- one quote per line.
        for (NSString *line in [blocks.firstObject componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmedLine.length > 0) [entries addObject:trimmedLine];
        }
    }

    for (NSString *entry in entries) {
        QuotesParsedQuote *parsed = [self parseOneEntry:entry];
        if (parsed.text.length > 0) [results addObject:parsed];
    }
    return results;
}

+ (NSString *)normalizeTextForDedupe:(NSString *)text {
    NSString *lower = text.lowercaseString;
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    NSMutableString *result = [NSMutableString string];
    BOOL lastWasSpace = YES; // suppress a leading space
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([alnum characterIsMember:c]) {
            [result appendFormat:@"%C", c];
            lastWasSpace = NO;
        } else if (!lastWasSpace) {
            [result appendString:@" "];
            lastWasSpace = YES;
        }
    }
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

@end

NS_ASSUME_NONNULL_END
