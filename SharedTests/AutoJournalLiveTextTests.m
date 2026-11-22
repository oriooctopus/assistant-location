// Journal recorder live transcript: what the preview shows (tail of the text, head dropped at a word) and the guard
// that keeps a slow translation reply from overwriting a newer one. Pure logic.
#import <XCTest/XCTest.h>
#import "../Modules/AutoJournal/AutoJournalLiveText.h"

@interface AutoJournalLiveTextTests : XCTestCase
@end

@implementation AutoJournalLiveTextTests

- (void)testShortTextIsUnchanged {
    XCTAssertEqualObjects([AutoJournalLiveText tailOfText:@"hello there" maxCharacters:50], @"hello there");
}

- (void)testExactFitIsUnchanged {
    XCTAssertEqualObjects([AutoJournalLiveText tailOfText:@"12345" maxCharacters:5], @"12345");
}

- (void)testLongTextKeepsTheNewestWordsWithLeadingEllipsis {
    NSString *tail = [AutoJournalLiveText tailOfText:@"one two three four five six" maxCharacters:14];
    XCTAssertEqualObjects(tail, @"…four five six");
}

- (void)testCutNeverStartsMidWord {
    // 12 chars back from the end lands inside "three"; the partial word is dropped, not shown as "ee four five".
    NSString *tail = [AutoJournalLiveText tailOfText:@"one two three four five" maxCharacters:12];
    XCTAssertTrue([tail hasPrefix:@"…"]);
    XCTAssertEqualObjects(tail, @"…four five");
}

- (void)testCutOnWordBoundaryKeepsTheWholeWord {
    NSString *tail = [AutoJournalLiveText tailOfText:@"alpha beta gamma" maxCharacters:10];
    XCTAssertEqualObjects(tail, @"…beta gamma");
}

- (void)testJoinCommittedAndPartial {
    XCTAssertEqualObjects([AutoJournalLiveText joinCommitted:@"first part" partial:@"second"], @"first part second");
    XCTAssertEqualObjects([AutoJournalLiveText joinCommitted:@"" partial:@"second"], @"second");
    XCTAssertEqualObjects([AutoJournalLiveText joinCommitted:@"first" partial:@""], @"first");
}

- (void)testOnlyTheNewestRequestIsCurrent {
    AutoJournalStaleGuard *guard = [[AutoJournalStaleGuard alloc] init];
    NSUInteger first = [guard begin];
    NSUInteger second = [guard begin];
    XCTAssertFalse([guard isCurrent:first], @"a reply for the older request must be dropped");
    XCTAssertTrue([guard isCurrent:second]);
}

- (void)testInvalidateStalesEverythingOutstanding {
    AutoJournalStaleGuard *guard = [[AutoJournalStaleGuard alloc] init];
    NSUInteger token = [guard begin];
    [guard invalidate];
    XCTAssertFalse([guard isCurrent:token]);
}

@end
