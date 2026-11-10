// Pure-logic tests for ListenSpeakPhrases: the spoken "I'm done" and "continue" control words a native Listen & speak
// turn matches against the on-device recognizer's transcript.
#import <XCTest/XCTest.h>
#import "ListenSpeakPhrases.h"

@interface ListenSpeakPhrasesTests : XCTestCase
@end

@implementation ListenSpeakPhrasesTests

- (void)testContinueAloneMatchesWhateverCaseOrPunctuation {
    for (NSString *t in @[@"continue", @"Continue", @"Continue.", @"CONTINUE!", @" continue "]) {
        XCTAssertTrue([ListenSpeakPhrases transcriptIsContinue:t], @"%@", t);
    }
}

- (void)testContinueInsideAnAnswerIsNotASkip {
    for (NSString *t in @[@"the story will continue tomorrow", @"continue please", @"please continue", @"", @"continued", @"I'm done"]) {
        XCTAssertFalse([ListenSpeakPhrases transcriptIsContinue:t], @"%@", t);
    }
}

- (void)testDoneMatchesOnlyAtTheEnd {
    for (NSString *t in @[@"I'm done", @"i am done.", @"im done", @"He went home and then I’m done!", @"so that's it, I'm done"]) {
        XCTAssertTrue([ListenSpeakPhrases transcriptEndsWithDone:t], @"%@", t);
    }
    for (NSString *t in @[@"I'm done with the first part", @"done", @"continue", @""]) {
        XCTAssertFalse([ListenSpeakPhrases transcriptEndsWithDone:t], @"%@", t);
    }
}

- (void)testPruneDeletesOnlyOldListenSpeakClips {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID UUID].UUIDString isDirectory:YES];
    NSFileManager *fm = [NSFileManager defaultManager];
    XCTAssertTrue([fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSDate *now = [NSDate date];
    NSURL *old = [dir URLByAppendingPathComponent:@"listen-speak-old.m4a"];
    NSURL *fresh = [dir URLByAppendingPathComponent:@"listen-speak-fresh.m4a"];
    NSURL *other = [dir URLByAppendingPathComponent:@"notes.txt"];
    for (NSURL *u in @[old, fresh, other]) XCTAssertTrue([@"x" writeToURL:u atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([fm setAttributes:@{NSFileModificationDate: [now dateByAddingTimeInterval:-100]} ofItemAtPath:old.path error:NULL]);
    XCTAssertTrue([fm setAttributes:@{NSFileModificationDate: [now dateByAddingTimeInterval:-100]} ofItemAtPath:other.path error:NULL]);
    XCTAssertEqual([ListenSpeakPhrases pruneRecordingsInDirectory:dir olderThan:50 now:now], 1u, @"only the old clip, not the old non-clip");
    XCTAssertFalse([fm fileExistsAtPath:old.path]);
    XCTAssertTrue([fm fileExistsAtPath:fresh.path]);
    XCTAssertTrue([fm fileExistsAtPath:other.path]);
    XCTAssertEqual([ListenSpeakPhrases pruneRecordingsInDirectory:[dir URLByAppendingPathComponent:@"missing"] olderThan:50 now:now], 0u);
    [fm removeItemAtURL:dir error:NULL];
}

@end
