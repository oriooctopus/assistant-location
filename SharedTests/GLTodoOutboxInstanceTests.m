// Instance-level tests for GLTodoOutbox: store round-tripping, handoff
// idempotency, and reclaim. These exercise the real NSURLSession delegate
// wiring (an ephemeral, non-background session, per
// -initWithStoreURL:serverBase:sessionConfiguration:), but every request is
// intercepted by GLTodoOutboxNeverRespondingProtocol below rather than
// hitting any real network -- deliberately, so a test that calls -reclaim
// "mid-flight" is racing against nothing: the request can never complete on
// its own, so there is no window for a real completion to land before the
// test's own synchronous assertions run.
#import <XCTest/XCTest.h>
#import "GLTodoOutbox.h"

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

// Counts + remembers upload task creation so a test can prove a doubled
// handoff never creates a second concurrent task, and so a test can drive a
// task's completion delegate callback manually (simulating a race against
// -reclaim) without a real network round trip.
@interface GLTodoOutboxCountingOutbox : GLTodoOutbox
@property(nonatomic, assign) NSUInteger createdTaskCount;
@property(nonatomic, strong, nullable) NSURLSessionUploadTask *lastCreatedTask;
@end

@implementation GLTodoOutboxCountingOutbox
- (NSURLSessionUploadTask *)createUploadTaskForRequest:(NSURLRequest *)request fromFileURL:(NSURL *)fileURL {
    self.createdTaskCount++;
    NSURLSessionUploadTask *task = [super createUploadTaskForRequest:request fromFileURL:fileURL];
    self.lastCreatedTask = task;
    return task;
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

- (void)testALateCompletionCallbackAfterReclaimCannotResurrectState {
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

@end
