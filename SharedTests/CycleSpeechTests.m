// The kept-clip file lifecycle of CycleSpeech (orphan sweep, ack). The recorder itself needs a mic and is not started here:
// clips are files dropped into an injected voice folder, which is all the sweep and the ack look at.
#import <XCTest/XCTest.h>
#import "CycleSpeech.h"

@interface CycleSpeechTests : XCTestCase
@property (nonatomic, strong) NSURL *dir;
@property (nonatomic, strong) CycleSpeech *speech;
@end

@implementation CycleSpeechTests

- (void)setUp {
    self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:NULL]);
    self.speech = [[CycleSpeech alloc] init];
    self.speech.voiceDirectory = self.dir;
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.dir error:NULL];
}

- (NSURL *)drop:(NSString *)name bytes:(NSString *)bytes {
    NSURL *url = [self.dir URLByAppendingPathComponent:name];
    XCTAssertTrue([[bytes dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES]);
    return url;
}

- (void)testOrphansListEveryUnackedClipWithItsIdAndBytes {
    [self drop:@"cycle-voice-AAA.m4a" bytes:@"one"];
    [self drop:@"cycle-voice-BBB.m4a" bytes:@"two"];
    NSArray<NSDictionary *> *orphans = [[self.speech orphanClips] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES]]];
    XCTAssertEqual(orphans.count, 2u);
    XCTAssertEqualObjects(orphans[0][@"id"], @"AAA");
    XCTAssertEqualObjects(orphans[0][@"audio"], [@"one" dataUsingEncoding:NSUTF8StringEncoding]);
    XCTAssertEqualObjects(orphans[1][@"id"], @"BBB");
}

- (void)testOrphansIgnoreOtherFilesAndDeleteEmptyOnes {
    [self drop:@"notes.txt" bytes:@"x"];
    NSURL *empty = [self drop:@"cycle-voice-EMPTY.m4a" bytes:@""];
    XCTAssertEqual([self.speech orphanClips].count, 0u);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:empty.path], @"an empty recording is deleted");
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self.dir URLByAppendingPathComponent:@"notes.txt"].path]);
}

- (void)testOrphansOfAMissingFolderIsEmpty {
    self.speech.voiceDirectory = [self.dir URLByAppendingPathComponent:@"nope"];
    XCTAssertEqual([self.speech orphanClips].count, 0u);
}

- (void)testAckDeletesOnlyThatClipAndIsIdempotent {
    NSURL *a = [self drop:@"cycle-voice-AAA.m4a" bytes:@"one"];
    NSURL *b = [self drop:@"cycle-voice-BBB.m4a" bytes:@"two"];
    XCTAssertTrue([self.speech ackClip:@"AAA"]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:a.path]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:b.path]);
    XCTAssertTrue([self.speech ackClip:@"AAA"], @"acking twice is fine");
    XCTAssertEqual([self.speech orphanClips].count, 1u);
}

- (void)testAckRefusesAnIdThatIsNotAPlainClipId {
    NSURL *outside = [self.dir.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"cycle-voice-x.m4a"];
    [[@"keep" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:outside atomically:YES];
    for (NSString *bad in @[@"", @"../cycle-voice-x", @"a/b", @".hidden"]) {
        XCTAssertFalse([self.speech ackClip:bad], @"%@", bad);
    }
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:outside.path]);
    [NSFileManager.defaultManager removeItemAtURL:outside error:NULL];
}

- (void)testIdleFinishAndCancelTouchNothing {
    NSURL *a = [self drop:@"cycle-voice-AAA.m4a" bytes:@"one"];
    XCTAssertNil([self.speech finishClip]);
    [self.speech cancel];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:a.path], @"a kept clip survives a cancel of a recording that never ran");
}

@end
