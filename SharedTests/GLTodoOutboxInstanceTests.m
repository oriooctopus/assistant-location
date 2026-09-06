// Instance-level tests for GLTodoOutbox: store round-tripping, handoff
// idempotency, reclaim, cold-relaunch adoption, and the full upload-
// completion path (classification, persistence, chain advance, request
// construction). Two request stubs are used, deliberately for different
// purposes:
//
//   - GLTodoOutboxNeverRespondingProtocol: a request that never completes,
//     for tests about the IN-FLIGHT state (reclaim, stale-callback
//     rejection, relaunch adoption) where a real completion racing the
//     test's own assertions would make them flaky.
//   - GLTodoOutboxRespondingProtocol: a request that DOES complete, with a
//     scripted status/body (or a transport error) and a record of the
//     request it actually received -- this is the only way to reach
//     -URLSession:task:didCompleteWithError:, where success classification,
//     persistence, chain advance, and the staleness guard all live.
#import <XCTest/XCTest.h>
#import "GLTodoOutbox.h"

static NSData *GLTodoOutboxOkBodyData(void) {
    return [NSJSONSerialization dataWithJSONObject:@{@"ok": @YES} options:0 error:nil];
}

// Intercepts every request and never calls back to its client -- simulates
// a request that never completes (the in-flight state -reclaim must halt),
// with zero real networking and zero timing dependence.
@interface GLTodoOutboxNeverRespondingProtocol : NSURLProtocol
@end

@implementation GLTodoOutboxNeverRespondingProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}
- (void)startLoading {
    // Deliberately does nothing -- the task just sits in flight forever.
}
- (void)stopLoading {
    // Nothing was ever started that needs tearing down.
}
@end

#pragma mark - Responding protocol stub (scriptable per request)

// The wire-level shape of one request GLTodoOutboxRespondingProtocol
// actually received -- method, URL, and the JSON body decoded (reading the
// upload's staged file via HTTPBodyStream when HTTPBody itself is nil,
// which is how an -uploadTaskWithRequest:fromFile: request's body arrives).
@interface GLTodoOutboxRecordedRequest : NSObject
@property(nonatomic, copy) NSString *HTTPMethod;
@property(nonatomic, copy) NSURL *URL;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *decodedBody;
@end

@implementation GLTodoOutboxRecordedRequest
@end

@interface GLTodoOutboxRespondingProtocol : NSURLProtocol
@end

static NSMutableArray *gGLTodoOutboxScriptQueue;
static NSMutableArray<GLTodoOutboxRecordedRequest *> *gGLTodoOutboxRecordedRequests;

@implementation GLTodoOutboxRespondingProtocol

+ (void)reset {
    @synchronized ([GLTodoOutboxRespondingProtocol class]) {
        gGLTodoOutboxScriptQueue = [NSMutableArray array];
        gGLTodoOutboxRecordedRequests = [NSMutableArray array];
    }
}

// Enqueued responses are consumed in FIFO order by successive requests --
// safe because GLTodoOutbox only ever has one upload in flight at a time
// (see the class header comment on strict sequencing), so requests to this
// stub never overlap.
+ (void)enqueueStatus:(NSInteger)status body:(NSData *)body {
    @synchronized ([GLTodoOutboxRespondingProtocol class]) {
        [gGLTodoOutboxScriptQueue addObject:@{@"status": @(status), @"body": body}];
    }
}

+ (void)enqueueTransportError {
    @synchronized ([GLTodoOutboxRespondingProtocol class]) {
        [gGLTodoOutboxScriptQueue addObject:[NSError errorWithDomain:NSURLErrorDomain
                                                                  code:NSURLErrorNotConnectedToInternet
                                                              userInfo:nil]];
    }
}

+ (NSArray<GLTodoOutboxRecordedRequest *> *)recordedRequests {
    @synchronized ([GLTodoOutboxRespondingProtocol class]) {
        return [gGLTodoOutboxRecordedRequests copy];
    }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSData *bodyData = self.request.HTTPBody;
    if (bodyData == nil && self.request.HTTPBodyStream != nil) {
        NSInputStream *stream = self.request.HTTPBodyStream;
        [stream open];
        NSMutableData *data = [NSMutableData data];
        uint8_t buffer[4096];
        NSInteger n;
        while ((n = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
            [data appendBytes:buffer length:n];
        }
        [stream close];
        bodyData = data;
    }

    NSDictionary *decodedBody = nil;
    if (bodyData.length > 0) {
        id parsed = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) decodedBody = parsed;
    }
    GLTodoOutboxRecordedRequest *recorded = [GLTodoOutboxRecordedRequest new];
    recorded.HTTPMethod = self.request.HTTPMethod;
    recorded.URL = self.request.URL;
    recorded.decodedBody = decodedBody;

    id script;
    @synchronized ([GLTodoOutboxRespondingProtocol class]) {
        [gGLTodoOutboxRecordedRequests addObject:recorded];
        script = gGLTodoOutboxScriptQueue.firstObject;
        if (script != nil) [gGLTodoOutboxScriptQueue removeObjectAtIndex:0];
    }

    if ([script isKindOfClass:[NSError class]]) {
        [self.client URLProtocol:self didFailWithError:(NSError *)script];
        return;
    }
    NSDictionary *scripted = script;
    NSInteger status = scripted != nil ? [scripted[@"status"] integerValue] : 200;
    NSData *responseBody = scripted != nil ? scripted[@"body"] : GLTodoOutboxOkBodyData();

    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                                statusCode:status
                                                               HTTPVersion:@"HTTP/1.1"
                                                              headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:responseBody];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    // Nothing to tear down -- -startLoading always finishes synchronously.
}

@end

// Counts + remembers upload task creation so a test can prove a doubled
// handoff never creates a second concurrent task, drives a task's
// completion delegate callback manually (simulating a race against
// -reclaim, or a cold relaunch), and can be told to fulfil an expectation
// whenever a real completion is delivered.
@interface GLTodoOutboxCountingOutbox : GLTodoOutbox
@property(nonatomic, assign) NSUInteger createdTaskCount;
@property(nonatomic, strong, nullable) NSURLSessionUploadTask *lastCreatedTask;
@property(nonatomic, copy, nullable) void (^onTaskComplete)(void);
// Test seam for simulating a cold relaunch: when non-nil,
// -adoptOutstandingUploadOrResumeChain is handed this instead of asking the
// real (per-instance, ephemeral) test session for its tasks -- an ephemeral
// session has no cross-instance state to find in the first place, so this
// is what stands in for "the reconnected background session says this task
// is still running."
@property(nonatomic, copy, nullable) NSArray<NSURLSessionUploadTask *> *injectedOutstandingTasksForRelaunch;
@end

@implementation GLTodoOutboxCountingOutbox

- (NSURLSessionUploadTask *)createUploadTaskForRequest:(NSURLRequest *)request fromFileURL:(NSURL *)fileURL {
    self.createdTaskCount++;
    NSURLSessionUploadTask *task = [super createUploadTaskForRequest:request fromFileURL:fileURL];
    self.lastCreatedTask = task;
    return task;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error {
    [super URLSession:session task:task didCompleteWithError:error];
    if (self.onTaskComplete != nil) self.onTaskComplete();
}

- (void)getOutstandingUploadTasksWithCompletionHandler:(void (^)(NSArray<NSURLSessionUploadTask *> *tasks))completionHandler {
    if (self.injectedOutstandingTasksForRelaunch != nil) {
        completionHandler(self.injectedOutstandingTasksForRelaunch);
        return;
    }
    [super getOutstandingUploadTasksWithCompletionHandler:completionHandler];
}

@end

@interface GLTodoOutboxInstanceTests : XCTestCase
@property(nonatomic, copy) NSURL *storeURL;
@end

@implementation GLTodoOutboxInstanceTests

- (void)setUp {
    [super setUp];
    NSString *name = [NSString stringWithFormat:@"gl-todo-outbox-test-%@.json", [NSUUID UUID].UUIDString];
    self.storeURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [GLTodoOutboxRespondingProtocol reset];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtURL:self.storeURL error:nil];
    [super tearDown];
}

- (GLTodoOutboxCountingOutbox *)makeOutbox {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.protocolClasses = @[[GLTodoOutboxNeverRespondingProtocol class]];
    return [[GLTodoOutboxCountingOutbox alloc] initWithStoreURL:self.storeURL
                                                       serverBase:@"http://198.51.100.1:1"
                                            sessionConfiguration:config];
}

// A request made against this actually completes (scripted per-call via
// GLTodoOutboxRespondingProtocol) -- for tests that need to reach
// -URLSession:task:didCompleteWithError:.
- (GLTodoOutboxCountingOutbox *)makeScriptedOutbox {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.protocolClasses = @[[GLTodoOutboxRespondingProtocol class]];
    return [[GLTodoOutboxCountingOutbox alloc] initWithStoreURL:self.storeURL
                                                       serverBase:@"http://198.51.100.1:1"
                                            sessionConfiguration:config];
}

- (GLTodoOutboxOp *)opWithId:(NSString *)opId {
    return [[GLTodoOutboxOp alloc] initWithOpId:opId path:@"/api/swipe" body:@{@"taskId": opId}];
}

#pragma mark - Store round-trip

- (void)testStoreRoundTripsToDiskWithOrderPreservedAcrossAReload {
    NSArray<GLTodoOutboxOp *> *ops = @[[self opWithId:@"a"], [self opWithId:@"b"], [self opWithId:@"c"]];

    GLTodoOutboxCountingOutbox *first = [self makeOutbox];
    [first handoffWithOps:ops];

    // A fresh instance pointed at the SAME file, simulating a cold relaunch
    // reading whatever the previous process last wrote -- never the same
    // in-memory object.
    GLTodoOutboxCountingOutbox *reloaded = [self makeOutbox];
    GLTodoOutboxState *state = [reloaded loadState];

    XCTAssertEqualObjects(state.remaining, ops, @"order must survive the round trip");
    XCTAssertEqual(state.sent.count, 0u);
    XCTAssertNil(state.failed);
}

#pragma mark - Handoff idempotency

- (void)testDoubledHandoffWithIdenticalOpsCreatesOnlyOneUploadTask {
    NSArray<GLTodoOutboxOp *> *ops = @[[self opWithId:@"a"], [self opWithId:@"b"]];
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];

    NSInteger firstAccepted = [outbox handoffWithOps:ops];
    // Simulates iOS firing `hidden` immediately followed by `pagehide` for
    // the same visibility change -- the exact scenario the header comment
    // calls out. Nothing else happens in between; the store on disk is
    // still exactly `ops`.
    NSInteger secondAccepted = [outbox handoffWithOps:ops];

    XCTAssertEqual(firstAccepted, (NSInteger)ops.count);
    XCTAssertEqual(secondAccepted, (NSInteger)ops.count);
    XCTAssertEqual(outbox.createdTaskCount, 1u, @"a doubled handoff must never start a second concurrent upload");

    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqualObjects(state.remaining, ops, @"REPLACE semantics: still exactly the one batch, not duplicated");
}

- (void)testHandoffWithGenuinelyDifferentOpsIsNotTreatedAsADuplicate {
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];
    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    XCTAssertEqual(outbox.createdTaskCount, 1u);

    [outbox handoffWithOps:@[[self opWithId:@"a"], [self opWithId:@"b"]]];
    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqualObjects(state.remaining, (@[[self opWithId:@"a"], [self opWithId:@"b"]]));
}

// H2: a genuinely different handoff (not caught by the identical-ops
// idempotency guard above) must still never start a SECOND concurrent
// upload while one is already in flight -- the one-in-flight gate in
// -startNextUploadIfNeeded is what's responsible for that, a separate guard
// from the idempotency check.
- (void)testGenuinelyDifferentHandoffWhileAnUploadIsInFlightDoesNotStartASecondConcurrentTask {
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];
    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    XCTAssertEqual(outbox.createdTaskCount, 1u, @"the head op should already be uploading");

    // Genuinely different (extra op "b") -- REPLACES the store, but must
    // defer to whatever is already running rather than starting a second
    // concurrent upload.
    [outbox handoffWithOps:@[[self opWithId:@"a"], [self opWithId:@"b"]]];

    XCTAssertEqual(outbox.createdTaskCount, 1u,
                   @"a second concurrent upload must never be started while one is already in flight");
}

#pragma mark - Reclaim

- (void)testReclaimReturnsCorrectSentRemainingSplitAndLeavesNoStateBehind {
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];
    GLTodoOutboxOp *a = [self opWithId:@"a"];
    GLTodoOutboxOp *b = [self opWithId:@"b"];
    [outbox handoffWithOps:@[a, b]];
    XCTAssertEqual(outbox.createdTaskCount, 1u, @"the head op should already be uploading");

    NSDictionary *result = [outbox reclaim];

    // Nothing has actually completed (the server is unroutable), so
    // everything handed off is still `remaining` -- none of it moved to
    // `sent` just because reclaim was called.
    XCTAssertEqualObjects(result[@"sent"], (@[]));
    NSArray *remaining = result[@"remaining"];
    XCTAssertEqual(remaining.count, 2u);
    XCTAssertEqualObjects(remaining[0][@"opId"], @"a");
    XCTAssertEqualObjects(remaining[1][@"opId"], @"b");
    XCTAssertEqualObjects(remaining[0][@"path"], @"/api/swipe");
    XCTAssertEqualObjects(result[@"failed"], [NSNull null]);

    // The store itself must be left EMPTY -- the web side owns it now.
    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqual(state.remaining.count, 0u);
    XCTAssertEqual(state.sent.count, 0u);
    XCTAssertNil(state.failed);
}

// D7: reclaim must clear `activeTask`, not just cancel the task and leave
// the pointer set -- otherwise the one-in-flight gate blocks EVERY upload
// forever after the first reclaim, since it thinks something is
// permanently still running.
- (void)testReclaimClearsActiveTaskSoANewHandoffCanStartUploading {
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];
    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    XCTAssertEqual(outbox.createdTaskCount, 1u);

    [outbox reclaim];
    [outbox handoffWithOps:@[[self opWithId:@"b"]]];

    XCTAssertEqual(outbox.createdTaskCount, 2u,
                   @"reclaim must clear activeTask, or all background sync is dead after the first reclaim");
}

// D8: reclaim must actually CANCEL the in-flight task, not just drop
// GLTodoOutbox's own pointer to it -- an uncancelled task would keep
// running (and could still deliver callbacks) even though the store
// thinks nothing is queued.
- (void)testReclaimActuallyCancelsTheInFlightTaskNotJustDroppingItsReference {
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];
    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    NSURLSessionUploadTask *task = outbox.lastCreatedTask;
    XCTAssertNotNil(task);

    [outbox reclaim];

    // -cancel is asynchronous; give it a brief window to actually take
    // effect (no real network is involved, so this settles almost
    // immediately when reclaim behaves correctly).
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (task.state == NSURLSessionTaskStateRunning && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertNotEqual(task.state, NSURLSessionTaskStateRunning,
                       @"reclaim must actually cancel the in-flight task, not just drop the reference to it");
}

- (void)testALateCompletionCallbackAfterReclaimCannotResurrectState {
    // This is the SAME-PROCESS reclaim-staleness contract: reclaim itself
    // (in this process, in this call) nils activeTask before this late
    // callback for the task it just cancelled arrives. It is deliberately
    // NOT the cold-relaunch case -- see
    // testColdRelaunchAdoptsStillInFlightTaskAndTheChainResumesOnItsCompletion
    // below, where the SAME nil-activeTask starting condition must instead
    // be resolved by adoption, not treated as staleness. The two scenarios
    // look identical from inside -URLSession:task:didCompleteWithError:
    // (activeTask is nil either way); what tells them apart is whether
    // -adoptOutstandingUploadOrResumeChain ran first and found the task
    // still genuinely outstanding.
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];
    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    NSURLSessionUploadTask *inFlightTask = outbox.lastCreatedTask;
    XCTAssertNotNil(inFlightTask);

    [outbox reclaim];
    GLTodoOutboxState *afterReclaim = [outbox loadState];
    XCTAssertEqual(afterReclaim.remaining.count, 0u);

    // Simulate the cancelled task's completion delegate callback arriving
    // AFTER -reclaim already returned -- exactly the race the class header
    // comment calls out. Even a spoofed "success" (error == nil) must not
    // write anything: -reclaim already nilled out activeTask, so the
    // `task != self.activeTask` identity check must reject this callback.
    NSURLSession *unusedSessionArg = nil;
    [outbox URLSession:unusedSessionArg task:inFlightTask didCompleteWithError:nil];

    GLTodoOutboxState *afterLateCallback = [outbox loadState];
    XCTAssertEqual(afterLateCallback.remaining.count, 0u);
    XCTAssertEqual(afterLateCallback.sent.count, 0u);
    XCTAssertNil(afterLateCallback.failed, @"a late callback must not resurrect or corrupt the reclaimed (empty) state");
}

// D6: the same staleness guard must keep protecting a NEW head op, not just
// an empty reclaimed store -- a stale callback for an op that was already
// reclaimed away must not be misapplied to whatever the web side handed off
// next.
- (void)testStaleCallbackAfterReclaimAndReHandoffCannotCorruptTheNewHeadOp {
    GLTodoOutboxCountingOutbox *outbox = [self makeOutbox];
    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    NSURLSessionUploadTask *staleTask = outbox.lastCreatedTask;

    [outbox reclaim];
    [outbox handoffWithOps:@[[self opWithId:@"c"]]]; // web side re-hands-off after reclaiming
    XCTAssertEqual(outbox.createdTaskCount, 2u, @"a fresh task for c");

    // The stale task from "a"'s upload (already cancelled by reclaim)
    // delivers its completion callback late. Even though there IS a new op
    // "c" now at the head, this must not be misapplied to it.
    NSURLSession *unusedSessionArg = nil;
    [outbox URLSession:unusedSessionArg task:staleTask didCompleteWithError:nil];

    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqualObjects(state.remaining, (@[[self opWithId:@"c"]]),
                          @"the stale callback must not have been applied to the new head op");
    XCTAssertEqual(state.sent.count, 0u);
    XCTAssertNil(state.failed);
}

#pragma mark - Cold-relaunch adoption (the JOB 1 fix)

// The bug: `activeTask` is memory-only, so a freshly-relaunched process
// starts with it nil even though the background session it wraps still has
// this exact upload running -- before the fix, the completion below would
// be silently DROPPED by the very same `task != self.activeTask` guard that
// correctly protects the reclaim case above. What tells the two apart is
// -adoptOutstandingUploadOrResumeChain: called (by a test, explicitly) to
// stand in for the real background session reconnecting on launch, it must
// recognize this task as still genuinely outstanding and adopt it BEFORE
// this callback arrives.
- (void)testColdRelaunchAdoptsStillInFlightTaskAndTheChainResumesOnItsCompletion {
    // Simulates process 1: starts uploading op "a" (with "b" still queued
    // behind it); the request never completes (NeverResponding) -- this
    // instance is simply abandoned here, standing in for the process being
    // killed mid-upload.
    GLTodoOutboxCountingOutbox *priorProcess = [self makeOutbox];
    [priorProcess handoffWithOps:@[[self opWithId:@"a"], [self opWithId:@"b"]]];
    NSURLSessionUploadTask *stillInFlightTask = priorProcess.lastCreatedTask;
    XCTAssertNotNil(stillInFlightTask);

    // Simulates process 2 (the relaunch): a FRESH instance pointed at the
    // same on-disk store (self.storeURL is shared across -makeOutbox calls
    // within one test), whose activeTask starts out nil exactly like the
    // real bug. Its getOutstandingUploadTasksWithCompletionHandler: is
    // stubbed to hand back the still-outstanding task -- a real relaunch
    // would get this same answer from the reconnected background session;
    // that can't be simulated for real in a unit test (you can't have two
    // live NSURLSessions sharing one background identifier in one process).
    GLTodoOutboxCountingOutbox *relaunched = [self makeOutbox];
    relaunched.injectedOutstandingTasksForRelaunch = @[stillInFlightTask];
    [relaunched adoptOutstandingUploadOrResumeChain];

    // Drive the recovered task's completion as a success.
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://198.51.100.1:1/api/swipe"]
                                                                statusCode:200
                                                               HTTPVersion:@"HTTP/1.1"
                                                              headerFields:@{}];
    NSURLSession *unusedSessionArg = nil;
    [relaunched URLSession:unusedSessionArg
                   dataTask:(NSURLSessionDataTask *)stillInFlightTask
         didReceiveResponse:response
          completionHandler:^(NSURLSessionResponseDisposition disposition) {
    }];
    [relaunched URLSession:unusedSessionArg dataTask:(NSURLSessionDataTask *)stillInFlightTask didReceiveData:GLTodoOutboxOkBodyData()];
    [relaunched URLSession:unusedSessionArg task:stillInFlightTask didCompleteWithError:nil];

    GLTodoOutboxState *state = [relaunched loadState];
    XCTAssertEqualObjects(state.sent, (@[[self opWithId:@"a"]]),
                          @"the adopted task's completion must be applied, not silently dropped");
    XCTAssertEqualObjects(state.remaining, (@[[self opWithId:@"b"]]));
    XCTAssertNil(state.failed);
    // The chain must have actually resumed for "b" -- proves this isn't
    // just persisted but that -startNextUploadIfNeeded ran too, on the
    // RELAUNCHED instance itself.
    XCTAssertEqual(relaunched.createdTaskCount, 1u, @"the relaunched instance must have started uploading b");
}

#pragma mark - Completion classification, persistence, and chain advance

// D1: a captive-portal 200 (HTML body) must never be counted as sent --
// that would lose the write permanently.
- (void)testCaptivePortal200WithHtmlBodyIsRecordedAsFailedNotSent {
    NSData *html = [@"<html><body>Sign in to Wi-Fi</body></html>" dataUsingEncoding:NSUTF8StringEncoding];
    [GLTodoOutboxRespondingProtocol enqueueStatus:200 body:html];
    GLTodoOutboxCountingOutbox *outbox = [self makeScriptedOutbox];
    XCTestExpectation *expectation = [self expectationWithDescription:@"upload completed"];
    outbox.onTaskComplete = ^{ [expectation fulfill]; };

    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqualObjects(state.remaining, (@[[self opWithId:@"a"]]), @"a captive-portal 200 must not be counted as sent");
    XCTAssertEqual(state.sent.count, 0u);
    XCTAssertEqualObjects(state.failed[@"opId"], @"a");
    XCTAssertEqualObjects(state.failed[@"status"], @200);
}

// D3: a transport-level failure (offline) must never be counted as sent.
- (void)testTransportErrorIsRecordedAsFailedNotSent {
    [GLTodoOutboxRespondingProtocol enqueueTransportError];
    GLTodoOutboxCountingOutbox *outbox = [self makeScriptedOutbox];
    XCTestExpectation *expectation = [self expectationWithDescription:@"upload completed"];
    outbox.onTaskComplete = ^{ [expectation fulfill]; };

    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqualObjects(state.remaining, (@[[self opWithId:@"a"]]), @"offline must not be counted as sent -- the write would be lost");
    XCTAssertEqual(state.sent.count, 0u);
    XCTAssertEqualObjects(state.failed[@"opId"], @"a");
    XCTAssertEqualObjects(state.failed[@"status"], @0);
}

// D2: the STATUS governs whether a response is an HTTP error, not the body
// -- a 500 whose body happens to look like a success shape (shouldn't
// happen in practice, but must not matter) must still halt the chain.
- (void)testServerErrorStatusOverridesAnOkTrueBodyStillRecordedAsFailed {
    [GLTodoOutboxRespondingProtocol enqueueStatus:500 body:GLTodoOutboxOkBodyData()];
    GLTodoOutboxCountingOutbox *outbox = [self makeScriptedOutbox];
    XCTestExpectation *expectation = [self expectationWithDescription:@"upload completed"];
    outbox.onTaskComplete = ^{ [expectation fulfill]; };

    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqualObjects(state.remaining, (@[[self opWithId:@"a"]]));
    XCTAssertEqual(state.sent.count, 0u, @"a non-2xx status must halt the chain regardless of what the body looks like");
    XCTAssertEqualObjects(state.failed[@"status"], @500);
}

// D5: a success must advance the chain to the next op automatically.
- (void)testSuccessAdvancesTheChainToTheNextOpAutomatically {
    [GLTodoOutboxRespondingProtocol enqueueStatus:200 body:GLTodoOutboxOkBodyData()];
    [GLTodoOutboxRespondingProtocol enqueueStatus:200 body:GLTodoOutboxOkBodyData()];
    GLTodoOutboxCountingOutbox *outbox = [self makeScriptedOutbox];
    XCTestExpectation *expectation = [self expectationWithDescription:@"both uploads completed"];
    expectation.expectedFulfillmentCount = 2;
    outbox.onTaskComplete = ^{ [expectation fulfill]; };

    [outbox handoffWithOps:@[[self opWithId:@"a"], [self opWithId:@"b"]]];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    XCTAssertEqual(outbox.createdTaskCount, 2u, @"the chain must advance to op b automatically after a succeeds");
    GLTodoOutboxState *state = [outbox loadState];
    XCTAssertEqualObjects(state.sent, (@[[self opWithId:@"a"], [self opWithId:@"b"]]));
    XCTAssertEqual(state.remaining.count, 0u);
    XCTAssertNil(state.failed);
}

// P1: `sent` must actually be written to disk -- read back from a FRESH
// instance, so this can't pass off an in-memory value the first instance
// merely holds onto.
- (void)testSuccessPersistsSentToDiskReadableFromAFreshInstance {
    [GLTodoOutboxRespondingProtocol enqueueStatus:200 body:GLTodoOutboxOkBodyData()];
    GLTodoOutboxCountingOutbox *outbox = [self makeScriptedOutbox];
    XCTestExpectation *expectation = [self expectationWithDescription:@"upload completed"];
    outbox.onTaskComplete = ^{ [expectation fulfill]; };

    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    GLTodoOutboxCountingOutbox *reloaded = [self makeScriptedOutbox];
    GLTodoOutboxState *state = [reloaded loadState];
    XCTAssertEqualObjects(state.sent, (@[[self opWithId:@"a"]]));
    XCTAssertEqual(state.remaining.count, 0u);
}

// P2: `failed` must actually be written to disk -- otherwise a relaunch
// after a failure would see no failure recorded and could retry blindly.
- (void)testFailurePersistsFailedRecordToDiskReadableFromAFreshInstance {
    [GLTodoOutboxRespondingProtocol enqueueStatus:500 body:[@"{\"error\":\"boom\"}" dataUsingEncoding:NSUTF8StringEncoding]];
    GLTodoOutboxCountingOutbox *outbox = [self makeScriptedOutbox];
    XCTestExpectation *expectation = [self expectationWithDescription:@"upload completed"];
    outbox.onTaskComplete = ^{ [expectation fulfill]; };

    [outbox handoffWithOps:@[[self opWithId:@"a"]]];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    GLTodoOutboxCountingOutbox *reloaded = [self makeScriptedOutbox];
    GLTodoOutboxState *state = [reloaded loadState];
    XCTAssertEqualObjects(state.remaining, (@[[self opWithId:@"a"]]), @"a relaunch after a failure must still see the op as queued, not lost");
    XCTAssertEqualObjects(state.failed[@"opId"], @"a");
    XCTAssertEqualObjects(state.failed[@"status"], @500);
}

// R1/R2/R3: assert the ACTUAL request the stub received, not just the
// outcome -- opId must be injected into the body (the server dedupes on
// it), the method must be POST, and op.path must reach the request URL.
- (void)testUploadRequestIsAPostToTheOpsPathWithOpIdInjectedIntoTheBody {
    [GLTodoOutboxRespondingProtocol enqueueStatus:200 body:GLTodoOutboxOkBodyData()];
    GLTodoOutboxCountingOutbox *outbox = [self makeScriptedOutbox];
    XCTestExpectation *expectation = [self expectationWithDescription:@"upload completed"];
    outbox.onTaskComplete = ^{ [expectation fulfill]; };

    GLTodoOutboxOp *op = [[GLTodoOutboxOp alloc] initWithOpId:@"a"
                                                           path:@"/api/swipe"
                                                           body:@{@"taskId": @"t1", @"action": @"complete"}];
    [outbox handoffWithOps:@[op]];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    NSArray<GLTodoOutboxRecordedRequest *> *requests = [GLTodoOutboxRespondingProtocol recordedRequests];
    XCTAssertEqual(requests.count, 1u);
    GLTodoOutboxRecordedRequest *request = requests.firstObject;
    XCTAssertEqualObjects(request.HTTPMethod, @"POST");
    XCTAssertEqualObjects(request.URL.path, @"/api/swipe", @"op.path must reach the actual request URL");
    XCTAssertEqualObjects(request.decodedBody[@"opId"], @"a", @"opId must be injected into the body -- the server dedupes on it");
    XCTAssertEqualObjects(request.decodedBody[@"taskId"], @"t1");
    XCTAssertEqualObjects(request.decodedBody[@"action"], @"complete");
}

@end
