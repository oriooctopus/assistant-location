#import "ListenSpeakPhrases.h"

@implementation ListenSpeakPhrases

/// Lowercases, drops apostrophes (the recognizer varies between ' and ’, and sometimes omits them) and splits on
/// whitespace / punctuation, so "I'm done." and "im done" compare equal.
+ (NSArray<NSString *> *)wordsOf:(NSString *)transcript {
    NSMutableString *t = [[transcript lowercaseString] mutableCopy];
    for (NSString *apos in @[@"’", @"‘", @"'", @"`"]) {
        [t replaceOccurrencesOfString:apos withString:@"" options:0 range:NSMakeRange(0, t.length)];
    }
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *word in [t componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\n.,!?;:\"-"]]) {
        if (word.length) [words addObject:word];
    }
    return words;
}

+ (BOOL)transcriptEndsWithDone:(NSString *)transcript {
    NSString *norm = [[self wordsOf:transcript] componentsJoinedByString:@" "];
    for (NSString *tail in @[@"im done", @"i am done"]) {
        if ([norm isEqualToString:tail] || [norm hasSuffix:[@" " stringByAppendingString:tail]]) return YES;
    }
    return NO;
}

+ (BOOL)transcriptIsContinue:(NSString *)transcript {
    NSArray *words = [self wordsOf:transcript];
    return words.count == 1 && [words[0] isEqualToString:@"continue"];
}

@end
