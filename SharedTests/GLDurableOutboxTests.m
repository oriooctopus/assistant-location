// Tests for GLDurableOutbox, the disk-backed queue behind the offline
// data-loss fixes (AutoJournal note + photos, session voice prompt, Facebook
// quick reply). The bug class: user content existed only in memory or a temp
// dir while a request was in flight, so a dropped connection or an app kill
// lost it. Every test here drives a scripted NSURLProtocol (no network, no
// real endpoint, so no real message can ever be sent) and, for the
// relaunch cases, builds a SECOND outbox instance on the same directory.
#import <XCTest/XCTest.h>
#import "GLDurableOutbox.h"

@interface GLDurableRecordedRequest : NSObject
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSURL *URL;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property(nonatomic, copy) NSData *body;
@end
@implementation GLDurableRecordedRequest
@end

static NSMutableArray *gGLDurableScript;   // NSNumber status, or NSError
static NSMutableArray<GLDurableRecordedRequest *> *gGLDurableRecorded;

@interface GLDurableStubProtocol : NSURLProtocol
@end

@implementation GLDurableStubProtocol
+ (void)reset {
    @synchronized (self) {
        gGLDurableScript = [NSMutableArray array];
        gGLDurableRecorded = [NSMutableArray array];
    }
}
+ (void)scriptStatus:(NSInteger)status {
    @synchronized (self) { [gGLDurableScript addObject:@(status)]; }
}
+ (void)scriptTransportError {
    @synchronized (self) {
        [gGLDurableScript addObject:[NSError errorWithDomain:NSURLErrorDomain
                                                        code:NSURLErrorNotConnectedToInternet
                                                    userInfo:nil]];
    }
}
+ (NSArray<GLDurableRecordedRequest *> *)recorded {
    @synchronized (self) { return [gGLDurableRecorded copy]; }
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSData *body = self.request.HTTPBody;
    if (body == nil && self.request.HTTPBodyStream != nil) {
        NSInputStream *stream = self.request.HTTPBodyStream;
        [stream open];
        NSMutableData *data = [NSMutableData data];
        uint8_t buffer[4096];
        NSInteger n;
        while ((n = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [data appendBytes:buffer length:n];
        [stream close];
        body = data;
    }
    GLDurableRecordedRequest *rec = [GLDurableRecordedRequest new];
    rec.method = self.request.HTTPMethod;
    rec.URL = self.request.URL;
    rec.headers = self.request.allHTTPHeaderFields ?: @{};
    rec.body = body ?: [NSData data];
    id script;
    @synchronized ([GLDurableStubProtocol class]) {
        [gGLDurableRecorded addObject:rec];
        script = gGLDurableScript.firstObject;
        if (script) [gGLDurableScript removeObjectAtIndex:0];
    }
    if ([script isKindOfClass:[NSError class]]) {
        [self.client URLProtocol:self didFailWithError:script];
        return;
    }
    NSInteger status = script ? [script integerValue] : 200;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"{\"text\":\"hello\"}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

@interface GLDurableOutboxTests : XCTestCase
@property(nonatomic, strong) NSURL *dir;
@end

@implementation GLDurableOutboxTests

- (void)setUp {
    [GLDurableStubProtocol reset];
    self.dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"durable-outbox-%@", [NSUUID UUID].UUIDString]];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil];
}

/// A fresh outbox on self.dir -- calling this twice simulates an app relaunch.
- (GLDurableOutbox *)makeOutbox {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.protocolClasses = @[[GLDurableStubProtocol class]];
    GLDurableOutbox *outbox = [[GLDurableOutbox alloc]
        initWithDirectory:self.dir
               urlBuilder:^NSURL *(NSString *path) {
                   return [NSURL URLWithString:[@"http://box.invalid:8302" stringByAppendingString:path]];
               }
                    token:@"tok-123"
     sessionConfiguration:config];
    outbox.retryInterval = 3600; // retry timer must not fire during a test
    return outbox;
}

- (NSString *)enqueueNote:(GLDurableOutbox *)outbox text:(NSString *)text kind:(NSString *)kind {
    NSError *error = nil;
    NSString *itemID = [outbox enqueueKind:kind
                                      path:@"/drop"
                                   headers:@{@"X-Filename": @"journal-note-1.md", @"Content-Type": @"application/octet-stream"}
                                      body:[text dataUsingEncoding:NSUTF8StringEncoding]
                                      meta:@{@"k": @"v"}
                                keepResult:NO
                          acceptedStatuses:nil
                                     error:&error];
    XCTAssertNotNil(itemID, @"enqueue failed: %@", error);
    return itemID;
}

- (void)flush:(GLDurableOutbox *)outbox {
    XCTestExpectation *done = [self expectationWithDescription:@"flush"];
    [outbox flushWithCompletion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:15];
}

#pragma mark - Bug 1/2/4: a network failure must leave the content on disk

- (void)testNetworkFailureKeepsItemOnDiskAndRelaunchRetriesItToSuccess {
    GLDurableOutbox *first = [self makeOutbox];
    NSString *itemID = [self enqueueNote:first text:@"thought I must not lose" kind:@"journal-note"];

    [GLDurableStubProtocol scriptTransportError];
    [self flush:first];
    XCTAssertEqual(first.items.count, 1u, @"a transport failure must keep the item");
    NSDictionary *item = [first itemWithID:itemID];
    XCTAssertEqualObjects(item[@"state"], GLDurableOutboxStatePending);
    XCTAssertEqual([item[@"attempts"] integerValue], 1);

    // "Relaunch": a brand new instance over the same directory.
    GLDurableOutbox *second = [self makeOutbox];
    XCTAssertEqual(second.items.count, 1u, @"the item must survive the process dying");
    [GLDurableStubProtocol scriptStatus:200];
    [self flush:second];
    XCTAssertEqual(second.items.count, 0u, @"a delivered item must be removed");

    NSArray<GLDurableRecordedRequest *> *reqs = [GLDurableStubProtocol recorded];
    XCTAssertEqual(reqs.count, 2u);
    XCTAssertEqualObjects(reqs.lastObject.method, @"POST");
    XCTAssertEqualObjects(reqs.lastObject.URL.absoluteString, @"http://box.invalid:8302/drop");
    XCTAssertEqualObjects(reqs.lastObject.headers[@"Authorization"], @"Bearer tok-123");
    XCTAssertEqualObjects(reqs.lastObject.headers[@"X-Filename"], @"journal-note-1.md");
    XCTAssertEqualObjects([[NSString alloc] initWithData:reqs.lastObject.body encoding:NSUTF8StringEncoding],
                          @"thought I must not lose", @"the replay must carry the original body bytes");
}

- (void)testEnqueueWritesToDiskBeforeAnySendHappens {
    GLDurableOutbox *outbox = [self makeOutbox];
    [self enqueueNote:outbox text:@"saved first" kind:@"journal-note"];
    XCTAssertEqual([GLDurableStubProtocol recorded].count, 0u, @"enqueue must not send; it only persists");
    XCTAssertEqual([self makeOutbox].items.count, 1u, @"item must be on disk right after enqueue");
}

- (void)testTokenIsNeverPersistedToDisk {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSString *itemID = [self enqueueNote:outbox text:@"x" kind:@"journal-note"];
    NSData *manifest = [NSData dataWithContentsOfURL:[self.dir URLByAppendingPathComponent:[itemID stringByAppendingString:@".json"]]];
    XCTAssertNotNil(manifest);
    XCTAssertFalse([[[NSString alloc] initWithData:manifest encoding:NSUTF8StringEncoding] containsString:@"tok-123"]);
}

#pragma mark - HTTP rejection is never retried

- (void)testHttpRejectionIsMarkedRejectedNotRetriedAndPostsNotification {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSString *itemID = [self enqueueNote:outbox text:@"refused" kind:@"facebook-reply"];

    XCTestExpectation *rejected = [self expectationForNotification:GLDurableOutboxDidRejectNotification
                                                            object:nil
                                                           handler:^BOOL(NSNotification *n) {
        return [n.userInfo[@"item"][@"kind"] isEqualToString:@"facebook-reply"];
    }];
    [GLDurableStubProtocol scriptStatus:400];
    [self flush:outbox];
    [self waitForExpectations:@[rejected] timeout:5];

    NSDictionary *item = [outbox itemWithID:itemID];
    XCTAssertEqualObjects(item[@"state"], GLDurableOutboxStateRejected);
    XCTAssertEqual([item[@"rejectedStatus"] integerValue], 400);

    [self flush:outbox];
    [self flush:[self makeOutbox]];
    XCTAssertEqual([GLDurableStubProtocol recorded].count, 1u, @"a 4xx must never be sent again");
}

- (void)testServerErrorIsAlsoRejectedNotRetried {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSString *itemID = [self enqueueNote:outbox text:@"boom" kind:@"journal-note"];
    [GLDurableStubProtocol scriptStatus:500];
    [self flush:outbox];
    [self flush:outbox];
    XCTAssertEqualObjects([outbox itemWithID:itemID][@"state"], GLDurableOutboxStateRejected);
    XCTAssertEqual([GLDurableStubProtocol recorded].count, 1u);
}

- (void)testRejectedItemDoesNotBlockLaterItems {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSString *bad = [self enqueueNote:outbox text:@"bad" kind:@"journal-note"];
    NSString *good = [self enqueueNote:outbox text:@"good" kind:@"journal-note"];
    [GLDurableStubProtocol scriptStatus:400];
    [GLDurableStubProtocol scriptStatus:200];
    [self flush:outbox];
    XCTAssertEqualObjects([outbox itemWithID:bad][@"state"], GLDurableOutboxStateRejected);
    XCTAssertNil([outbox itemWithID:good], @"the later item must have been delivered and removed");
}

- (void)testRetryRejectedItemSendsItAgain {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSString *itemID = [self enqueueNote:outbox text:@"again" kind:@"journal-note"];
    [GLDurableStubProtocol scriptStatus:400];
    [self flush:outbox];
    [outbox retryRejectedItemID:itemID];
    [GLDurableStubProtocol scriptStatus:200];
    [self flush:outbox];
    XCTAssertNil([outbox itemWithID:itemID]);
    XCTAssertEqual([GLDurableStubProtocol recorded].count, 2u);
}

#pragma mark - Ordering

- (void)testItemsAreSentOldestFirst {
    GLDurableOutbox *outbox = [self makeOutbox];
    [self enqueueNote:outbox text:@"one" kind:@"journal-note"];
    [self enqueueNote:outbox text:@"two" kind:@"journal-note"];
    [self enqueueNote:outbox text:@"three" kind:@"journal-note"];
    [self flush:outbox];
    NSMutableArray *order = [NSMutableArray array];
    for (GLDurableRecordedRequest *r in [GLDurableStubProtocol recorded]) {
        [order addObject:[[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding]];
    }
    NSArray *expected = @[@"one", @"two", @"three"];
    XCTAssertEqualObjects(order, expected);
}

- (void)testTransportFailureStopsThePassSoLaterItemsKeepTheirOrder {
    GLDurableOutbox *outbox = [self makeOutbox];
    [self enqueueNote:outbox text:@"one" kind:@"journal-note"];
    [self enqueueNote:outbox text:@"two" kind:@"journal-note"];
    [GLDurableStubProtocol scriptTransportError];
    [self flush:outbox];
    XCTAssertEqual([GLDurableStubProtocol recorded].count, 1u, @"offline: don't hammer every item");
    XCTAssertEqual(outbox.items.count, 2u);
}

#pragma mark - Bug 3: keepResult (voice transcript) + 422 acceptance

- (void)testKeepResultStoresResponseUntilAcknowledged {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSError *error = nil;
    NSString *itemID = [outbox enqueueKind:@"session-voice" path:@"/sessions/transcribe"
                                   headers:@{@"Content-Type": @"audio/m4a"}
                                      body:[@"AUDIO" dataUsingEncoding:NSUTF8StringEncoding]
                                      meta:nil keepResult:YES acceptedStatuses:@[@422] error:&error];
    XCTAssertNotNil(itemID);

    [GLDurableStubProtocol scriptTransportError];
    [self flush:outbox];
    XCTAssertEqualObjects([outbox itemWithID:itemID][@"state"], GLDurableOutboxStatePending,
                          @"offline: the recording must be kept for retry");

    // Relaunch, box reachable now.
    GLDurableOutbox *second = [self makeOutbox];
    [GLDurableStubProtocol scriptStatus:200];
    [self flush:second];
    NSDictionary *item = [second itemWithID:itemID];
    XCTAssertEqualObjects(item[@"state"], GLDurableOutboxStateCompleted);
    NSData *result = [second resultDataForItemID:itemID];
    XCTAssertNotNil(result, @"the transcript must be kept until the page acknowledges it");
    XCTAssertEqualObjects([NSJSONSerialization JSONObjectWithData:result options:0 error:nil][@"text"], @"hello");

    // Survives another relaunch until acked.
    XCTAssertNotNil([[self makeOutbox] resultDataForItemID:itemID]);
    [second removeItemID:itemID];
    XCTAssertNil([second itemWithID:itemID]);
    XCTAssertNil([second resultDataForItemID:itemID]);
}

- (void)testAcceptedStatusCountsAsCompletedNotRejected {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSError *error = nil;
    NSString *itemID = [outbox enqueueKind:@"session-voice" path:@"/sessions/transcribe" headers:@{}
                                      body:[@"A" dataUsingEncoding:NSUTF8StringEncoding]
                                      meta:nil keepResult:YES acceptedStatuses:@[@422] error:&error];
    [GLDurableStubProtocol scriptStatus:422];
    [self flush:outbox];
    NSDictionary *item = [outbox itemWithID:itemID];
    XCTAssertEqualObjects(item[@"state"], GLDurableOutboxStateCompleted);
    XCTAssertEqual([item[@"resultStatus"] integerValue], 422);
}

#pragma mark - Bug 4: the Facebook reply wire shape (stub only, never a real send)

- (void)testFacebookReplyPersistsJsonWithOpIdAndReplaysWithTheSameOpId {
    NSDictionary *params = @{
        @"category": @"facebook-reply",
        @"data": @{@"listing": @"L-1", @"buyer": @"Pat"},
        @"text": @"Yes, still available",
        @"opId": [NSUUID UUID].UUIDString,
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:params options:0 error:nil];
    GLDurableOutbox *first = [self makeOutbox];
    NSError *error = nil;
    NSString *itemID = [first enqueueKind:@"facebook-reply" path:@"/push/reply"
                                  headers:@{@"Content-Type": @"application/json"}
                                     body:json meta:@{@"buyer": @"Pat", @"listing": @"L-1"}
                               keepResult:NO acceptedStatuses:nil error:&error];
    XCTAssertNotNil(itemID);
    [GLDurableStubProtocol scriptTransportError];
    [self flush:first];

    GLDurableOutbox *second = [self makeOutbox];
    XCTAssertEqual(second.items.count, 1u, @"the reply text must survive a failed send plus a relaunch");
    [GLDurableStubProtocol scriptStatus:200];
    [self flush:second];
    XCTAssertEqual(second.items.count, 0u);

    NSArray<GLDurableRecordedRequest *> *reqs = [GLDurableStubProtocol recorded];
    XCTAssertEqual(reqs.count, 2u);
    NSDictionary *a = [NSJSONSerialization JSONObjectWithData:reqs[0].body options:0 error:nil];
    NSDictionary *b = [NSJSONSerialization JSONObjectWithData:reqs[1].body options:0 error:nil];
    XCTAssertEqualObjects(b[@"text"], @"Yes, still available");
    XCTAssertEqualObjects(b[@"opId"], a[@"opId"], @"replay must reuse the opId so the server dedupes");
    XCTAssertEqualObjects(reqs[1].URL.path, @"/push/reply");
}

#pragma mark - Robustness of the store itself

- (void)testEnqueueFailureReturnsNilWithAnError {
    GLDurableOutbox *outbox = [self makeOutbox];
    // Replace the store directory with a regular file so every write fails.
    [[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil];
    [[NSFileManager defaultManager] createFileAtPath:self.dir.path contents:[NSData data] attributes:nil];
    NSError *error = nil;
    NSString *itemID = [outbox enqueueKind:@"journal-note" path:@"/drop" headers:@{}
                                      body:[@"x" dataUsingEncoding:NSUTF8StringEncoding]
                                      meta:nil keepResult:NO acceptedStatuses:nil error:&error];
    XCTAssertNil(itemID, @"callers must be told the content was NOT saved so they keep it on screen");
    XCTAssertNotNil(error);
}

- (void)testRemoveItemDeletesItFromDisk {
    GLDurableOutbox *outbox = [self makeOutbox];
    NSString *itemID = [self enqueueNote:outbox text:@"cancel me" kind:@"journal-photo"];
    [outbox removeItemID:itemID];
    XCTAssertEqual([self makeOutbox].items.count, 0u);
}

@end
