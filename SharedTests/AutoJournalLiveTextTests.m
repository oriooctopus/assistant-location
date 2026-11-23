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

- (void)testLevelClampsAtTheFloorAndAtFullScale {
    XCTAssertEqual([AutoJournalLiveText levelForDecibels:-50 floorDb:-50], 0);
    XCTAssertEqual([AutoJournalLiveText levelForDecibels:-160 floorDb:-50], 0, @"silence reads -160 and must not go negative");
    XCTAssertEqual([AutoJournalLiveText levelForDecibels:0 floorDb:-50], 1);
    XCTAssertEqual([AutoJournalLiveText levelForDecibels:6 floorDb:-50], 1, @"clipping stays within 0..1");
}

- (void)testLevelIsLinearInDecibelsBetweenTheFloorAndZero {
    XCTAssertEqualWithAccuracy([AutoJournalLiveText levelForDecibels:-25 floorDb:-50], 0.5, 0.0001);
    XCTAssertEqualWithAccuracy([AutoJournalLiveText levelForDecibels:-10 floorDb:-50], 0.8, 0.0001);
}

- (void)testLevelBufferStartsFlatAndDropsTheOldest {
    AutoJournalLevelBuffer *buf = [[AutoJournalLevelBuffer alloc] initWithCapacity:3];
    XCTAssertEqualObjects(buf.levels, (@[@0, @0, @0]));
    [buf push:0.2];
    [buf push:0.4];
    [buf push:0.6];
    XCTAssertEqualObjects(buf.levels, (@[@0.2, @0.4, @0.6]));
    [buf push:0.8];
    XCTAssertEqualObjects(buf.levels, (@[@0.4, @0.6, @0.8]), @"oldest falls off the left, newest at the right");
    [buf push:3];
    XCTAssertEqualObjects(buf.levels.lastObject, @1, @"pushed levels are clamped to 0..1");
    [buf clear];
    XCTAssertEqualObjects(buf.levels, (@[@0, @0, @0]));
}

- (void)testDecibelListParsing {
    NSArray *want = @[@-40, @-20, @-5];
    XCTAssertEqualObjects([AutoJournalLiveText decibelListFromString:@"-40, -20,-5"], want);
    XCTAssertEqualObjects([AutoJournalLiveText decibelListFromString:@"-40,,x, -20 ,-5,"], want, @"blank and invalid entries are dropped");
}

- (void)testSummaryLineReflectsTitleAndSwitches {
    XCTAssertEqualObjects([AutoJournalLiveText summaryLineForTitle:nil tweet:NO esme:NO], @"Title (optional)");
    XCTAssertEqualObjects([AutoJournalLiveText summaryLineForTitle:@"  \n" tweet:NO esme:NO], @"Title (optional)");
    XCTAssertEqualObjects([AutoJournalLiveText summaryLineForTitle:@" Lunch walk " tweet:NO esme:NO], @"Lunch walk");
    XCTAssertEqualObjects([AutoJournalLiveText summaryLineForTitle:@"" tweet:YES esme:NO], @"Title (optional) \u00B7 Tweet");
    XCTAssertEqualObjects([AutoJournalLiveText summaryLineForTitle:@"" tweet:NO esme:YES], @"Title (optional) \u00B7 Esme");
    XCTAssertEqualObjects([AutoJournalLiveText summaryLineForTitle:@"" tweet:YES esme:YES],
                          @"Title (optional) \u00B7 Tweet \u00B7 Esme");
}

@end
