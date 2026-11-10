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

+ (NSURL *)recordingsDirectory {
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ListenSpeak" isDirectory:YES];
}

+ (NSUInteger)pruneRecordingsInDirectory:(NSURL *)directory olderThan:(NSTimeInterval)maxAge now:(NSDate *)now {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                                            includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                               options:0
                                                                                 error:NULL];
    NSUInteger deleted = 0;
    for (NSURL *file in files) {
        if (![file.lastPathComponent hasPrefix:@"listen-speak-"] || ![file.lastPathComponent hasSuffix:@".m4a"]) continue;
        NSDate *modified = nil;
        [file getResourceValue:&modified forKey:NSURLContentModificationDateKey error:NULL];
        if (modified && [now timeIntervalSinceDate:modified] > maxAge && [[NSFileManager defaultManager] removeItemAtURL:file error:NULL]) deleted++;
    }
    return deleted;
}

@end
