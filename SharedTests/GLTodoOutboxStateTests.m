// Pure state-machine tests for GLTodoOutboxState -- no NSURLSession, no
// disk, no networking at all. See GLTodoOutbox.h's header comment: this is
// exactly the "plain testable ... class method" the design calls for so
// the sequencing decision can be proven correct with no live session.
#import <XCTest/XCTest.h>
#import "GLTodoOutbox.h"

@interface GLTodoOutboxStateTests : XCTestCase
@end

@implementation GLTodoOutboxStateTests

- (GLTodoOutboxOp *)opWithId:(NSString *)opId {
    return [[GLTodoOutboxOp alloc] initWithOpId:opId path:@"/api/swipe" body:@{@"taskId": @"t1", @"action": @"complete"}];
}

- (void)testEmptyStateHasNothingQueuedOrSent {
    GLTodoOutboxState *state = [GLTodoOutboxState emptyState];
    XCTAssertEqual(state.remaining.count, 0u);
    XCTAssertEqual(state.sent.count, 0u);
    XCTAssertNil(state.failed);
    XCTAssertNil(state.nextOpToSend);
}

- (void)testSuccessAdvancesHeadOpToSentAndClearsAnyFailure {
    GLTodoOutboxOp *a = [self opWithId:@"a"];
    GLTodoOutboxOp *b = [self opWithId:@"b"];
    GLTodoOutboxState *state = [[GLTodoOutboxState alloc] initWithRemaining:@[a, b] sent:@[] failed:nil];

    GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeSuccess status:200];

    XCTAssertEqualObjects(next.remaining, (@[b]));
    XCTAssertEqualObjects(next.sent, (@[a]));
    XCTAssertNil(next.failed);
    XCTAssertEqualObjects(next.nextOpToSend, b);
}

- (void)testSuccessOnLastRemainingOpEmptiesTheQueue {
    GLTodoOutboxOp *a = [self opWithId:@"a"];
    GLTodoOutboxState *state = [[GLTodoOutboxState alloc] initWithRemaining:@[a] sent:@[] failed:nil];

    GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeSuccess status:200];

    XCTAssertEqual(next.remaining.count, 0u);
    XCTAssertEqualObjects(next.sent, (@[a]));
    XCTAssertNil(next.nextOpToSend);
}

- (void)testHttpErrorHaltsChainWithRemainingUnchangedAndRecordsStatus {
    GLTodoOutboxOp *a = [self opWithId:@"a"];
    GLTodoOutboxOp *b = [self opWithId:@"b"];
    GLTodoOutboxState *state = [[GLTodoOutboxState alloc] initWithRemaining:@[a, b] sent:@[] failed:nil];

    GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeHTTPError status:500];

    // remaining is UNCHANGED: `a` stays at the head, never skipped.
    XCTAssertEqualObjects(next.remaining, (@[a, b]));
    XCTAssertEqual(next.sent.count, 0u);
    XCTAssertEqualObjects(next.failed[@"opId"], @"a");
    XCTAssertEqualObjects(next.failed[@"status"], @500);
    // The chain is halted -- nextOpToSend is nil even though `a` is still there.
    XCTAssertNil(next.nextOpToSend);
}

- (void)test4xxHaltsChainAndRecordsStatus {
    GLTodoOutboxOp *a = [self opWithId:@"a"];
    GLTodoOutboxState *state = [[GLTodoOutboxState alloc] initWithRemaining:@[a] sent:@[] failed:nil];

    GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeHTTPError status:400];

    XCTAssertEqualObjects(next.remaining, (@[a]));
    XCTAssertEqualObjects(next.failed[@"status"], @400);
    XCTAssertNil(next.nextOpToSend);
}

- (void)testTransportErrorHaltsChainWithStatusZero {
    GLTodoOutboxOp *a = [self opWithId:@"a"];
    GLTodoOutboxState *state = [[GLTodoOutboxState alloc] initWithRemaining:@[a] sent:@[] failed:nil];

    GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeTransportError status:0];

    XCTAssertEqualObjects(next.remaining, (@[a]));
    XCTAssertEqualObjects(next.failed[@"opId"], @"a");
    XCTAssertEqualObjects(next.failed[@"status"], @0);
    XCTAssertNil(next.nextOpToSend);
}

// The captive-portal case: a 200 whose body is not the shape todo-sorter's
// server actually returns (an object with ok == true). Must NOT be treated
// as sent -- treating it as sent would lose the write permanently.
- (void)testUnexpectedBodyOn200HaltsChainRatherThanCountingAsSent {
    GLTodoOutboxOp *a = [self opWithId:@"a"];
    GLTodoOutboxState *state = [[GLTodoOutboxState alloc] initWithRemaining:@[a] sent:@[] failed:nil];

    GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeUnexpectedBody status:200];

    XCTAssertEqualObjects(next.remaining, (@[a]));
    XCTAssertEqual(next.sent.count, 0u);
    XCTAssertEqualObjects(next.failed[@"opId"], @"a");
    XCTAssertEqualObjects(next.failed[@"status"], @200);
}

#pragma mark - Response-body success-shape check

- (void)testResponseBodyIndicatesSuccessRequiresOkTrueObject {
    NSData *okBody = [NSJSONSerialization dataWithJSONObject:@{@"ok": @YES, @"result": @{}} options:0 error:nil];
    XCTAssertTrue([GLTodoOutbox responseBodyIndicatesSuccess:okBody]);
}

- (void)testResponseBodyIndicatesSuccessRejectsOkFalse {
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"ok": @NO} options:0 error:nil];
    XCTAssertFalse([GLTodoOutbox responseBodyIndicatesSuccess:body]);
}

- (void)testResponseBodyIndicatesSuccessRejectsHtmlCaptivePortalBody {
    NSData *html = [@"<html><body>Sign in to Wi-Fi</body></html>" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertFalse([GLTodoOutbox responseBodyIndicatesSuccess:html]);
}

- (void)testResponseBodyIndicatesSuccessRejectsJsonWithoutOkKey {
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"items": @[]} options:0 error:nil];
    XCTAssertFalse([GLTodoOutbox responseBodyIndicatesSuccess:body]);
}

- (void)testResponseBodyIndicatesSuccessRejectsEmptyBody {
    XCTAssertFalse([GLTodoOutbox responseBodyIndicatesSuccess:[NSData data]]);
    XCTAssertFalse([GLTodoOutbox responseBodyIndicatesSuccess:nil]);
}

#pragma mark - GLTodoOutboxOp parsing

- (void)testOpFromDictionaryParsesWellFormedOp {
    GLTodoOutboxOp *op = [GLTodoOutboxOp opFromDictionary:@{@"opId": @"o1", @"path": @"/api/swipe", @"body": @{@"taskId": @"t1"}}];
    XCTAssertNotNil(op);
    XCTAssertEqualObjects(op.opId, @"o1");
    XCTAssertEqualObjects(op.path, @"/api/swipe");
    XCTAssertEqualObjects(op.body, (@{@"taskId": @"t1"}));
}

- (void)testOpFromDictionaryRejectsMissingOpId {
    // Extra parens around the whole message send are load-bearing here,
    // not style: the dictionary literal's commas are only "inside ()" (and
    // so protected from being mis-parsed as macro-argument separators by
    // the preprocessor) once this whole expression is itself wrapped in
    // one -- [] and {} don't protect a macro argument's top-level commas,
    // only () does.
    XCTAssertNil(([GLTodoOutboxOp opFromDictionary:@{@"path": @"/api/swipe", @"body": @{}}]));
}

- (void)testOpFromDictionaryRejectsWrongTypedBody {
    XCTAssertNil(([GLTodoOutboxOp opFromDictionary:@{@"opId": @"o1", @"path": @"/api/swipe", @"body": @"not a dict"}]));
}

- (void)testOpFromDictionaryRejectsNonDictionaryInput {
    XCTAssertNil([GLTodoOutboxOp opFromDictionary:(id)@[@"nope"]]);
}

@end
