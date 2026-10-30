// The take-to-song math behind Back to song and the section highlight, plus the
// take list on disk. The upload path needs a server, so sim-test covers it.

#import <XCTest/XCTest.h>
#import "ClipsTakesStore.h"
#import "GLDurableOutbox.h"

static NSInteger gAlignStatus;
static NSString *gAlignBody;

/// Answers every request with gAlignStatus and gAlignBody, in place of the box.
@interface ClipsAlignStubProtocol : NSURLProtocol
- (NSDictionary *)syncedTakeAnswering:(NSInteger)status body:(NSString *)body {
    gAlignStatus = status;
    gAlignBody = body;
    NSURL *url = [self.syncedStore newRecordingURL];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToURL:url atomically:YES]);
    return [self.syncedStore addTakeAtURL:url toClip:@"a" duration:4];
}

- (void)sync {
    XCTestExpectation *done = [self expectationWithDescription:@"sync"];
    [self.syncedStore syncAlignmentsForClip:@"a" completion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:10];
}

- (void)testAnAnswerIsSavedOntoTheTakeAndLeavesTheQueue {
    [self syncedTakeAnswering:200 body:@"{\"duration\":4,\"map\":[[0,10],[0.5,10.5]]}"];
    [self sync];
    XCTAssertEqualObjects([self.syncedStore takesForClip:@"a"].firstObject[@"map"], (@[@[@0, @10], @[@0.5, @10.5]]));
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testARejectedUploadLeavesTheTakePlayableAndUnplaced {
    [self syncedTakeAnswering:400 body:@"{\"error\":\"could not decode audio\"}"];
    [self sync];
    NSDictionary *take = [self.syncedStore takesForClip:@"a"].firstObject;
    XCTAssertNotNil(take);
    XCTAssertNil(take[@"map"]);
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testDeletingATakeRemovesItsQueuedUpload {
    NSDictionary *take = [self syncedTakeAnswering:200 body:@"{\"map\":[]}"];
    XCTAssertEqual(self.outbox.items.count, 1u);
    [self.syncedStore deleteTake:take[@"id"] inClip:@"a"];
    XCTAssertEqual(self.outbox.items.count, 0u);
}

@end

@implementation ClipsAlignStubProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:gAlignStatus HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[gAlignBody dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
- (NSDictionary *)syncedTakeAnswering:(NSInteger)status body:(NSString *)body {
    gAlignStatus = status;
    gAlignBody = body;
    NSURL *url = [self.syncedStore newRecordingURL];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToURL:url atomically:YES]);
    return [self.syncedStore addTakeAtURL:url toClip:@"a" duration:4];
}

- (void)sync {
    XCTestExpectation *done = [self expectationWithDescription:@"sync"];
    [self.syncedStore syncAlignmentsForClip:@"a" completion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:10];
}

- (void)testAnAnswerIsSavedOntoTheTakeAndLeavesTheQueue {
    [self syncedTakeAnswering:200 body:@"{\"duration\":4,\"map\":[[0,10],[0.5,10.5]]}"];
    [self sync];
    XCTAssertEqualObjects([self.syncedStore takesForClip:@"a"].firstObject[@"map"], (@[@[@0, @10], @[@0.5, @10.5]]));
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testARejectedUploadLeavesTheTakePlayableAndUnplaced {
    [self syncedTakeAnswering:400 body:@"{\"error\":\"could not decode audio\"}"];
    [self sync];
    NSDictionary *take = [self.syncedStore takesForClip:@"a"].firstObject;
    XCTAssertNotNil(take);
    XCTAssertNil(take[@"map"]);
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testDeletingATakeRemovesItsQueuedUpload {
    NSDictionary *take = [self syncedTakeAnswering:200 body:@"{\"map\":[]}"];
    XCTAssertEqual(self.outbox.items.count, 1u);
    [self.syncedStore deleteTake:take[@"id"] inClip:@"a"];
    XCTAssertEqual(self.outbox.items.count, 0u);
}

@end

@interface ClipsTakesStoreTests : XCTestCase
@property (nonatomic, strong) NSURL *dir;
@property (nonatomic, strong) ClipsTakesStore *store;
@property (nonatomic, strong) GLDurableOutbox *outbox;
@property (nonatomic, strong) ClipsTakesStore *syncedStore;
- (NSDictionary *)syncedTakeAnswering:(NSInteger)status body:(NSString *)body {
    gAlignStatus = status;
    gAlignBody = body;
    NSURL *url = [self.syncedStore newRecordingURL];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToURL:url atomically:YES]);
    return [self.syncedStore addTakeAtURL:url toClip:@"a" duration:4];
}

- (void)sync {
    XCTestExpectation *done = [self expectationWithDescription:@"sync"];
    [self.syncedStore syncAlignmentsForClip:@"a" completion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:10];
}

- (void)testAnAnswerIsSavedOntoTheTakeAndLeavesTheQueue {
    [self syncedTakeAnswering:200 body:@"{\"duration\":4,\"map\":[[0,10],[0.5,10.5]]}"];
    [self sync];
    XCTAssertEqualObjects([self.syncedStore takesForClip:@"a"].firstObject[@"map"], (@[@[@0, @10], @[@0.5, @10.5]]));
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testARejectedUploadLeavesTheTakePlayableAndUnplaced {
    [self syncedTakeAnswering:400 body:@"{\"error\":\"could not decode audio\"}"];
    [self sync];
    NSDictionary *take = [self.syncedStore takesForClip:@"a"].firstObject;
    XCTAssertNotNil(take);
    XCTAssertNil(take[@"map"]);
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testDeletingATakeRemovesItsQueuedUpload {
    NSDictionary *take = [self syncedTakeAnswering:200 body:@"{\"map\":[]}"];
    XCTAssertEqual(self.outbox.items.count, 1u);
    [self.syncedStore deleteTake:take[@"id"] inClip:@"a"];
    XCTAssertEqual(self.outbox.items.count, 0u);
}

@end

@implementation ClipsTakesStoreTests

// A take that played song 10-11, stopped being recognisable, then played song 40-40.5.
static NSArray *GapMap(void) {
    return @[@[@0, @10], @[@0.5, @10.5], @[@1, @11], @[@5, @40], @[@5.5, @40.5]];
}

- (void)setUp {
    self.dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID UUID].UUIDString];
    self.store = [[ClipsTakesStore alloc] initWithDirectory:self.dir outbox:^GLDurableOutbox *{ return nil; }];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.protocolClasses = @[[ClipsAlignStubProtocol class]];
    self.outbox = [[GLDurableOutbox alloc] initWithDirectory:[self.dir URLByAppendingPathComponent:@"outbox"]
                                                  urlBuilder:^NSURL *(NSString *path) { return [NSURL URLWithString:[@"http://box.invalid" stringByAppendingString:path]]; }
                                                       token:@"t"
                                        sessionConfiguration:config];
    __weak typeof(self) weakSelf = self;
    self.syncedStore = [[ClipsTakesStore alloc] initWithDirectory:self.dir outbox:^GLDurableOutbox *{ return weakSelf.outbox; }];
}

- (void)tearDown { [[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil]; }

- (void)testSongTimeInterpolatesBetweenPoints {
    XCTAssertEqualWithAccuracy([ClipsTakesStore songTimeForTakeTime:0.75 inMap:GapMap()].doubleValue, 10.75, 0.001);
    XCTAssertEqualWithAccuracy([ClipsTakesStore songTimeForTakeTime:5.2 inMap:GapMap()].doubleValue, 40.2, 0.001);
}

- (void)testSongTimeIsNilInsideAGap {
    XCTAssertNil([ClipsTakesStore songTimeForTakeTime:3 inMap:GapMap()]);
}

- (void)testSongTimePastTheLastPoint {
    XCTAssertEqualWithAccuracy([ClipsTakesStore songTimeForTakeTime:5.6 inMap:GapMap()].doubleValue, 40.5, 0.001);
    XCTAssertNil([ClipsTakesStore songTimeForTakeTime:7 inMap:GapMap()]);
}

- (void)testSongTimeWithNoMapIsNil {
    XCTAssertNil([ClipsTakesStore songTimeForTakeTime:1 inMap:nil]);
    XCTAssertNil([ClipsTakesStore songTimeForTakeTime:1 inMap:@[]]);
}

// A restart jumps the song position: a blended answer would name a moment never played.
- (void)testSongTimeNeverBlendsAcrossAJump {
    NSArray *jump = @[@[@0, @10], @[@0.5, @60]];
    XCTAssertEqualWithAccuracy([ClipsTakesStore songTimeForTakeTime:0.1 inMap:jump].doubleValue, 10, 0.001);
    XCTAssertEqualWithAccuracy([ClipsTakesStore songTimeForTakeTime:0.4 inMap:jump].doubleValue, 60, 0.001);
}

- (void)testTakeTimeFindsTheClosestPoint {
    XCTAssertEqualWithAccuracy([ClipsTakesStore takeTimeForSongTime:40.3 inMap:GapMap()].doubleValue, 5.5, 0.001);
}

- (void)testTakeTimeIsNilForAPassageNeverPlayed {
    XCTAssertNil([ClipsTakesStore takeTimeForSongTime:25 inMap:GapMap()]);
    XCTAssertNil([ClipsTakesStore takeTimeForSongTime:25 inMap:nil]);
}

- (void)testTakeTimePrefersTheFirstAttemptAtARepeatedPassage {
    NSArray *repeat = @[@[@0, @10], @[@5, @10]];
    XCTAssertEqualWithAccuracy([ClipsTakesStore takeTimeForSongTime:10 inMap:repeat].doubleValue, 0, 0.001);
}

- (NSDictionary *)addTakeToClip:(NSString *)clip {
    NSURL *url = [self.store newRecordingURL];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToURL:url atomically:YES]);
    return [self.store addTakeAtURL:url toClip:clip duration:4];
}

- (void)testTakesAreNewestFirstAndPerClip {
    NSDictionary *first = [self addTakeToClip:@"a"];
    NSDictionary *second = [self addTakeToClip:@"a"];
    [self addTakeToClip:@"b"];
    NSArray *ids = [[self.store takesForClip:@"a"] valueForKey:@"id"];
    XCTAssertEqualObjects(ids, (@[second[@"id"], first[@"id"]]));
}

- (void)testDeleteRemovesTheEntryAndTheFile {
    NSDictionary *take = [self addTakeToClip:@"a"];
    NSURL *file = [self.store fileURLForTake:take];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:file.path]);
    [self.store deleteTake:take[@"id"] inClip:@"a"];
    XCTAssertEqual([self.store takesForClip:@"a"].count, 0u);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:file.path]);
}

- (NSDictionary *)syncedTakeAnswering:(NSInteger)status body:(NSString *)body {
    gAlignStatus = status;
    gAlignBody = body;
    NSURL *url = [self.syncedStore newRecordingURL];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToURL:url atomically:YES]);
    return [self.syncedStore addTakeAtURL:url toClip:@"a" duration:4];
}

- (void)sync {
    XCTestExpectation *done = [self expectationWithDescription:@"sync"];
    [self.syncedStore syncAlignmentsForClip:@"a" completion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:10];
}

- (void)testAnAnswerIsSavedOntoTheTakeAndLeavesTheQueue {
    [self syncedTakeAnswering:200 body:@"{\"duration\":4,\"map\":[[0,10],[0.5,10.5]]}"];
    [self sync];
    XCTAssertEqualObjects([self.syncedStore takesForClip:@"a"].firstObject[@"map"], (@[@[@0, @10], @[@0.5, @10.5]]));
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testARejectedUploadLeavesTheTakePlayableAndUnplaced {
    [self syncedTakeAnswering:400 body:@"{\"error\":\"could not decode audio\"}"];
    [self sync];
    NSDictionary *take = [self.syncedStore takesForClip:@"a"].firstObject;
    XCTAssertNotNil(take);
    XCTAssertNil(take[@"map"]);
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testDeletingATakeRemovesItsQueuedUpload {
    NSDictionary *take = [self syncedTakeAnswering:200 body:@"{\"map\":[]}"];
    XCTAssertEqual(self.outbox.items.count, 1u);
    [self.syncedStore deleteTake:take[@"id"] inClip:@"a"];
    XCTAssertEqual(self.outbox.items.count, 0u);
}

@end
