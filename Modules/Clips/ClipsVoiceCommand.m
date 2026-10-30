#import "ClipsVoiceCommand.h"

static const NSTimeInterval kMinSectionLength = 0.1;
static const NSTimeInterval kDefaultSectionLength = 10;

static NSString *const kNumberWord = @"(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)";

static NSString *WordsPattern(void) {
    return [NSString stringWithFormat:@"(?:(?:a |an )?%@(?:[ -](?:and )?%@)*)\\b", kNumberWord, kNumberWord];
}

static NSString *NumberPattern(void) {
    return [NSString stringWithFormat:@"(?:\\d+(?:\\.\\d+)?|%@)", WordsPattern()];
}

/// A time that is unmistakably a time, with or without "at".
static NSString *StrictPattern(void) {
    NSString *n = NumberPattern();
    return [NSString stringWithFormat:@"(?:%@\\s*(?:minutes?|mins?)(?:,?\\s*(?:and\\s+)?%@(?:\\s*(?:seconds?|secs?))?)?|%@\\s*(?:seconds?|secs?)|\\d{1,3}[:.]\\d{2}(?:\\.\\d+)?)", n, n, n];
}

/// A plain number: a time only after "at" ("at 45", "at one twenty"), and never a tempo or a count.
static NSString *BarePattern(void) {
    return [NSString stringWithFormat:@"(?:(?:\\d{1,4}(?: \\d{2})?|%@)\\b(?!\\s*(?:%%|percent|bpm|bars?|measures?|times?|x)\\b))", WordsPattern()];
}

static NSString *TimePattern(void) {
    return [NSString stringWithFormat:@"(%@|%@)", StrictPattern(), BarePattern()];
}

static NSString *const kTimePrefix = @"(?:at|from|around|about)\\s+(?:the\\s+)?";
static NSString *const kTimeEnd = @"(?=[\\s,.:;!?-]|$)";

/// Every capture of the first match, in order, with "" for a group that did not take part.
static NSArray<NSString *> *Captures(NSString *pattern, NSString *s) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    if (!re) [NSException raise:NSInternalInconsistencyException format:@"ClipsVoiceCommand: bad pattern %@", pattern];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < m.numberOfRanges; i++) {
        NSRange r = [m rangeAtIndex:i];
        [out addObject:r.location == NSNotFound ? @"" : [s substringWithRange:r]];
    }
    return out;
}

static NSString *Trimmed(NSString *s) {
    NSMutableCharacterSet *set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [set addCharactersInString:@",.:;!?-"];
    return [s stringByTrimmingCharactersInSet:set];
}

static NSString *Capitalized(NSString *s) {
    if (s.length == 0) return s;
    return [[[s substringToIndex:1] uppercaseString] stringByAppendingString:[s substringFromIndex:1]];
}

/// "twenty five", "a hundred", "one hundred and twenty", or -1 when the words don't compose ("one two").
static NSInteger WordNumber(NSString *phrase) {
    static NSDictionary<NSString *, NSNumber *> *values;
    if (!values) {
        values = @{@"zero": @0, @"one": @1, @"two": @2, @"three": @3, @"four": @4, @"five": @5, @"six": @6, @"seven": @7,
                   @"eight": @8, @"nine": @9, @"ten": @10, @"eleven": @11, @"twelve": @12, @"thirteen": @13, @"fourteen": @14,
                   @"fifteen": @15, @"sixteen": @16, @"seventeen": @17, @"eighteen": @18, @"nineteen": @19, @"twenty": @20,
                   @"thirty": @30, @"forty": @40, @"fifty": @50, @"sixty": @60, @"seventy": @70, @"eighty": @80, @"ninety": @90};
    }
    NSInteger total = 0;
    BOOL any = NO;
    NSArray *tokens = [[phrase.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@" "] componentsSeparatedByString:@" "];
    for (NSString *token in tokens) {
        if (token.length == 0 || [token isEqualToString:@"a"] || [token isEqualToString:@"an"] || [token isEqualToString:@"and"]) continue;
        if ([token isEqualToString:@"hundred"]) {
            if (total >= 100) return -1;
            total = (any ? total : 1) * 100;
            any = YES;
            continue;
        }
        NSNumber *value = values[token];
        if (!value) return -1;
        NSInteger v = value.integerValue;
        if (v >= 10 ? total % 100 != 0 : total % 10 != 0) return -1;
        total += v;
        any = YES;
    }
    return any ? total : -1;
}

static double NumberValue(NSString *phrase) {
    return [phrase rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound
        ? phrase.doubleValue : (double)WordNumber(phrase);
}

@implementation ClipsVoiceCommand

+ (NSTimeInterval)secondsFromPhrase:(NSString *)raw {
    NSString *phrase = Trimmed(raw).lowercaseString;
    NSString *n = NumberPattern();
    NSArray *m = Captures([NSString stringWithFormat:@"^(%@)\\s*(?:minutes?|mins?)(?:,?\\s*(?:and\\s+)?(%@)(?:\\s*(?:seconds?|secs?))?)?$", n, n], phrase);
    if (m) {
        double minutes = NumberValue(m[1]);
        double seconds = [m[2] length] ? NumberValue(m[2]) : 0;
        return minutes < 0 || seconds < 0 ? -1 : minutes * 60 + seconds;
    }
    m = Captures([NSString stringWithFormat:@"^(%@)\\s*(?:seconds?|secs?)$", n], phrase);
    if (m) return NumberValue(m[1]);
    m = Captures(@"^(\\d+)[:. ](\\d{2}(?:\\.\\d+)?)$", phrase);
    if (m) return [m[2] doubleValue] < 60 ? [m[1] doubleValue] * 60 + [m[2] doubleValue] : -1;
    if (Captures(@"^\\d+$", phrase)) {
        // Speech renders "one twenty three" as 123, so three digits with valid seconds read as m:ss.
        NSInteger value = phrase.integerValue;
        if (phrase.length <= 2 || value % 100 >= 60) return value;
        return value / 100 * 60 + value % 100;
    }
    // "one twenty three" as words is 1:23; a lone small word is a count ("at one point"), not a time.
    NSArray *tokens = [[phrase stringByReplacingOccurrencesOfString:@"-" withString:@" "] componentsSeparatedByString:@" "];
    if (tokens.count >= 2) {
        NSInteger first = WordNumber(tokens[0]);
        NSInteger rest = WordNumber([[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)] componentsJoinedByString:@" "]);
        if (first >= 1 && first <= 9 && rest >= 10 && rest < 60) return first * 60 + rest;
    }
    NSInteger value = WordNumber(phrase);
    return value >= 10 ? value : -1;
}

/// Pulls a spoken time (or from-to range) off the front or the back of `text`.
+ (NSDictionary *)extractTimeFrom:(NSString *)text {
    NSString *time = TimePattern(), *strict = StrictPattern();
    NSArray *m = Captures([NSString stringWithFormat:@"^%@%@(?:\\s+mark)?%@(?:\\s+(?:to|through|until)\\s+%@%@)?", kTimePrefix, time, kTimeEnd, time, kTimeEnd], text);
    if (!m) m = Captures([NSString stringWithFormat:@"^(%@)(?:\\s+in(?!\\s+the\\b))?%@(?:\\s+(?:to|through|until)\\s+%@%@)?", strict, kTimeEnd, time, kTimeEnd], text);
    NSString *rest = m ? [text substringFromIndex:[m[0] length]] : nil;
    if (!m) {
        m = Captures([NSString stringWithFormat:@"(?:^|[\\s,.;:-]+)from\\s+%@\\s+(?:to|through|until)\\s+%@[.,!?]*$", time, time], text);
        if (!m) m = Captures([NSString stringWithFormat:@"(?:^|[\\s,.;:-]+)%@%@(?:\\s+mark)?()[.,!?]*$", kTimePrefix, time], text);
        if (!m) m = Captures([NSString stringWithFormat:@"(?:^|[\\s,.;:-]+)(%@)(?:\\s+in)?()[.,!?]*$", strict], text);
        if (m) rest = [text substringToIndex:text.length - [m[0] length]];
    }
    if (!m) return nil;
    NSTimeInterval start = [self secondsFromPhrase:m[1]];
    if (start < 0) return nil;
    NSTimeInterval end = m.count > 2 && [m[2] length] ? [self secondsFromPhrase:m[2]] : -1;
    return @{@"start": @(start), @"end": @(end), @"rest": Trimmed(rest)};
}

static NSDictionary *SectionContaining(NSArray<NSDictionary *> *sections, NSTimeInterval t) {
    for (NSDictionary *s in sections) {
        if (t >= [s[@"start"] doubleValue] && t < [s[@"end"] doubleValue]) return s;
    }
    return nil;
}

/// The section a note names at its start or end ("in the coda ...", "... in section 3"), or nil.
+ (NSDictionary *)extractSectionFrom:(NSString *)text sections:(NSArray<NSDictionary *> *)sections playhead:(NSTimeInterval)playhead {
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSUInteger i = 0; i < sections.count; i++) {
        NSString *name = sections[i][@"name"];
        NSMutableArray *loose = [NSMutableArray arrayWithObject:name]; // "in the coda"
        NSMutableArray *labelled = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%lu", (unsigned long)i + 1]]; // only after "section"
        NSRange colon = [name rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            [labelled addObject:[name substringToIndex:colon.location]];
            [loose addObject:Trimmed([name substringFromIndex:NSMaxRange(colon)])];
        }
        for (NSString *alias in [loose arrayByAddingObjectsFromArray:labelled]) {
            NSString *escaped = [NSRegularExpression escapedPatternForString:alias];
            NSString *lead = [loose containsObject:alias] ? @"in\\s+(?:the\\s+)?(?:section\\s+)?" : @"(?:in\\s+)?(?:the\\s+)?section\\s+";
            [candidates addObject:@{@"section": sections[i], @"length": @(alias.length), @"pattern": [NSString stringWithFormat:@"%@%@", lead, escaped]}];
        }
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"length"] compare:a[@"length"]]; }];
    NSDictionary *found = nil;
    NSNumber *foundLength = nil;
    NSString *rest = nil;
    for (NSDictionary *c in candidates) {
        NSArray *m = Captures([NSString stringWithFormat:@"^%@(?=[\\s,.:;!?-]|$)", c[@"pattern"]], text);
        NSString *remaining = m ? [text substringFromIndex:[m[0] length]] : nil;
        if (!m) {
            m = Captures([NSString stringWithFormat:@"[\\s,.;:-]+%@[.,!?]*$", c[@"pattern"]], text);
            if (m) remaining = [text substringToIndex:text.length - [m[0] length]];
        }
        if (!m) continue;
        // Two sections can share a word ("A: March", "A': March"): the one being played wins.
        if (!found) { found = c[@"section"]; foundLength = c[@"length"]; rest = remaining; }
        else if ([c[@"length"] isEqual:foundLength] && c[@"section"] == SectionContaining(sections, playhead)) { found = c[@"section"]; rest = remaining; }
    }
    if (!found) return nil;
    return @{@"section": found, @"rest": Trimmed(rest)};
}

/// The name in a section command, and whether it renames the current section rather than adding one.
+ (NSDictionary *)sectionNameIn:(NSString *)text hasTime:(BOOL)hasTime {
    NSString *kindWord = @"(?:section|marker)";
    for (NSString *pattern in @[@"^(?:this|current)(?:\\s+(?:section|part))?\\s+is\\s+(?:called|named)\\s+(.+)$",
                                @"^(?:call|name|rename)\\s+this(?:\\s+(?:section|part))?(?:\\s+to)?\\s+(.+)$"]) {
        NSArray *m = Captures(pattern, text);
        if (m) return @{@"name": m[1], @"rename": @YES};
    }
    NSArray *adding = @[[NSString stringWithFormat:@"^(?:add\\s+(?:a\\s+)?(?:new\\s+)?|new\\s+|a\\s+new\\s+)?%@\\s+(?:called|named)\\s+(.+)$", kindWord],
                        [NSString stringWithFormat:@"^(?:add\\s+(?:a\\s+)?(?:new\\s+)?|new\\s+|a\\s+new\\s+)%@\\s+(.+)$", kindWord],
                        [NSString stringWithFormat:@"^(?:a\\s+)?(?:new\\s+)?%@\\s+(?:starts|begins)(?:\\s+here)?(?:\\s+(?:called|named))?\\s+(.+)$", kindWord],
                        @"^(?:mark|marker)\\s+(?:this\\s+)?(?:as\\s+)?(.+)$"];
    for (NSString *pattern in adding) {
        NSArray *m = Captures(pattern, text);
        if (m) return @{@"name": m[1], @"rename": @NO};
    }
    if (hasTime) {
        NSArray *m = Captures(@"^(?:is\\s+)?(?:called|named)\\s+(.+)$", text);
        if (m) return @{@"name": m[1], @"rename": @NO};
    }
    return nil;
}

+ (NSDictionary *)commandFromTranscript:(NSString *)transcript sections:(NSArray<NSDictionary *> *)sections
                               playhead:(NSTimeInterval)playhead duration:(NSTimeInterval)duration {
    NSString *text = Trimmed(transcript);
    NSString *notePrefix = @"^(?:add\\s+)?(?:a\\s+)?note(?:\\s+that\\b|\\s*[:,]|\\b)\\s*";
    NSArray *prefix = Captures(notePrefix, text);
    if (prefix) text = Trimmed([text substringFromIndex:[prefix[0] length]]);

    NSDictionary *spoken = [self extractTimeFrom:text];
    BOOL timeIgnored = spoken && duration > 0 && [spoken[@"start"] doubleValue] >= duration;
    NSString *rest = spoken ? spoken[@"rest"] : text;
    BOOL hasTime = spoken && !timeIgnored;
    NSTimeInterval time = hasTime ? [spoken[@"start"] doubleValue] : playhead;
    NSTimeInterval rangeEnd = hasTime ? [spoken[@"end"] doubleValue] : -1;

    NSDictionary *named = [self sectionNameIn:rest hasTime:hasTime];
    if (named) {
        NSString *name = Capitalized(Trimmed(named[@"name"]));
        if (name.length == 0) return nil;
        NSDictionary *container = SectionContaining(sections, time);
        BOOL atItsStart = container && time - [container[@"start"] doubleValue] < kMinSectionLength;
        if (rangeEnd < 0 && container && ([named[@"rename"] boolValue] || atItsStart)) {
            return @{@"kind": @"rename", @"name": name, @"sectionID": container[@"id"], @"start": container[@"start"], @"timeIgnored": @(timeIgnored)};
        }
        NSTimeInterval end = rangeEnd > time ? rangeEnd : -1;
        if (end < 0 && container) end = [container[@"end"] doubleValue];
        if (end < 0) {
            for (NSDictionary *s in sections) {
                if ([s[@"start"] doubleValue] > time) { end = [s[@"start"] doubleValue]; break; }
            }
        }
        if (end < 0) end = duration > time ? duration : time + kDefaultSectionLength;
        if (duration > 0) end = MIN(end, duration);
        BOOL atTheEnd = end - time < kMinSectionLength; // the playhead sits at the very end: cover the last stretch instead
        if (atTheEnd) time = MAX(0, end - kDefaultSectionLength);
        NSMutableDictionary *section = [@{@"kind": @"section", @"name": name, @"start": @(time), @"end": @(end), @"timeIgnored": @(timeIgnored)} mutableCopy];
        if (container && !atItsStart && !atTheEnd) section[@"truncateID"] = container[@"id"];
        return section;
    }

    prefix = Captures(notePrefix, rest);
    if (prefix) rest = Trimmed([rest substringFromIndex:[prefix[0] length]]);
    if (!hasTime && !timeIgnored) {
        NSDictionary *inSection = [self extractSectionFrom:rest sections:sections playhead:playhead];
        if (inSection) {
            rest = inSection[@"rest"];
            NSDictionary *s = inSection[@"section"];
            // Already in that section: the playhead is the more exact place.
            if (playhead < [s[@"start"] doubleValue] || playhead >= [s[@"end"] doubleValue]) time = [s[@"start"] doubleValue];
        }
    }
    if (rest.length == 0) return nil;
    return @{@"kind": @"note", @"text": Capitalized(rest), @"time": @(time), @"timeIgnored": @(timeIgnored)};
}

@end
