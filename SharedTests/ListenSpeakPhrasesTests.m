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

@end
