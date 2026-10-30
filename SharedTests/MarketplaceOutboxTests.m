// Pure logic of the Marketplace reply outbox: request shape, durable
// persistence across a "relaunch" (new instance, same file), and the reject
// state. No network.
#import <XCTest/XCTest.h>
#import "MarketplaceOutbox.h"

@interface MarketplaceOutboxTests : XCTestCase
@property (nonatomic, strong) NSURL *file;
@end

@implementation MarketplaceOutboxTests

- (void)setUp {
    self.file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"mp-outbox-%@.json", NSUUID.UUID.UUIDString]]];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.file error:NULL];
}

- (void)testReplyBodyShapeMatchesServer {
    NSDictionary *body = [MarketplaceOutbox replyBodyForListing:@"Couch" buyer:@"Sam" text:@"Yes" opId:@"op1"];
    NSDictionary *expected = @{@"category": @"FB_REPLY", @"data": @{@"listing": @"Couch", @"buyer": @"Sam"}, @"text": @"Yes", @"opId": @"op1"};
    XCTAssertEqualObjects(body, expected);
}

- (void)testRequestIsBearerJSONPost {
    NSURL *base = [NSURL URLWithString:@"http://host:8324"];
    NSURLRequest *req = [MarketplaceOutbox requestWithBaseURL:base path:@"/reply" token:@"tok" body:@{@"a": @1}];
    XCTAssertEqualObjects(req.URL.absoluteString, @"http://host:8324/reply");
    XCTAssertEqualObjects(req.HTTPMethod, @"POST");
    XCTAssertEqualObjects([req valueForHTTPHeaderField:@"Authorization"], @"Bearer tok");
    XCTAssertEqualObjects([req valueForHTTPHeaderField:@"Content-Type"], @"application/json");
    XCTAssertEqualObjects([NSJSONSerialization JSONObjectWithData:req.HTTPBody options:0 error:NULL], @{@"a": @1});
}

- (void)testEnqueuedReplySurvivesRelaunch {
    MarketplaceOutbox *a = [[MarketplaceOutbox alloc] initWithFileURL:self.file];
    NSError *error = nil;
    NSDictionary *item = [a enqueueReplyForListing:@"Couch" buyer:@"Sam" text:@"Yes" error:&error];
    XCTAssertNotNil(item, @"enqueue failed: %@", error);

    MarketplaceOutbox *b = [[MarketplaceOutbox alloc] initWithFileURL:self.file];
    XCTAssertEqual(b.pendingItems.count, 1u);
    XCTAssertEqualObjects(b.pendingItems[0][@"id"], item[@"id"], @"the opId must be stable across relaunch so the server dedupes a retry");
    XCTAssertEqualObjects(b.pendingItems[0][@"text"], @"Yes");
}

- (void)testApproveCategoryHasApproveAndReplyActions {
    UNNotificationCategory *approve = nil, *reply = nil;
    for (UNNotificationCategory *c in MarketplaceOutbox.notificationCategories) {
        if ([c.identifier isEqualToString:@"FB_APPROVE"]) approve = c;
        if ([c.identifier isEqualToString:@"FB_REPLY"]) reply = c;
    }
    XCTAssertNotNil(approve);
    XCTAssertNotNil(reply);
    XCTAssertEqual(approve.actions.count, 2u);
    XCTAssertEqualObjects(approve.actions[0].identifier, @"APPROVE");
    XCTAssertEqualObjects(approve.actions[0].title, @"Approve");
    XCTAssertEqual(approve.actions[0].options, UNNotificationActionOptionNone, @"Approve must run in the background with no unlock");
    XCTAssertEqualObjects(approve.actions[1].identifier, @"REPLY");
    XCTAssertTrue([approve.actions[1] isKindOfClass:UNTextInputNotificationAction.class]);
    XCTAssertEqual(reply.actions.count, 1u);
    XCTAssertEqualObjects(reply.actions[0].identifier, @"REPLY");
}

- (void)testDefaultTapOpensThreadForBothCategories {
    XCTAssertTrue([MarketplaceOutbox categoryOpensThread:@"FB_REPLY"]);
    XCTAssertTrue([MarketplaceOutbox categoryOpensThread:@"FB_APPROVE"]);
    XCTAssertFalse([MarketplaceOutbox categoryOpensThread:@""]);
}

- (void)testRejectedItemIsNotPending {
    MarketplaceOutbox *o = [[MarketplaceOutbox alloc] initWithFileURL:self.file];
    NSDictionary *item = [o enqueueReplyForListing:@"Couch" buyer:@"Sam" text:@"Yes" error:NULL];
    [o markRejectedItemWithID:item[@"id"] error:@"HTTP 400"];
    XCTAssertEqual(o.pendingItems.count, 0u);
    XCTAssertEqualObjects([o itemWithID:item[@"id"]][@"lastError"], @"HTTP 400");
    MarketplaceOutbox *reloaded = [[MarketplaceOutbox alloc] initWithFileURL:self.file];
    XCTAssertEqual(reloaded.pendingItems.count, 0u, @"a rejected reply must never be retried after relaunch");
}

- (void)testResolvedIdentifiersOnlyQuestionsNoLongerPending {
    NSDictionary *delivered = @{
        @"answered": @{@"question": @YES, @"listing": @"Couch", @"buyer": @"Sam"},
        @"pending": @{@"question": @YES, @"listing": @"Couch", @"buyer": @"Ana"},
        @"otherListing": @{@"question": @YES, @"listing": @"Desk", @"buyer": @"Ana"},
        @"pickupBooked": @{@"listing": @"Couch", @"buyer": @"Sam"},
        @"plainAlert": @{},
    };
    NSArray *questions = @[@{@"context": @{@"listing": @"Couch", @"buyer": @"Ana"}}];
    NSArray *resolved = [[MarketplaceOutbox resolvedIdentifiersInDelivered:delivered questions:questions] sortedArrayUsingSelector:@selector(compare:)];
    XCTAssertEqualObjects(resolved, (@[@"answered", @"otherListing"]));
}

- (void)testRemoveDeletesItem {
    MarketplaceOutbox *o = [[MarketplaceOutbox alloc] initWithFileURL:self.file];
    NSDictionary *item = [o enqueueReplyForListing:@"Couch" buyer:@"Sam" text:@"Yes" error:NULL];
    [o removeItemWithID:item[@"id"]];
    XCTAssertEqual([[MarketplaceOutbox alloc] initWithFileURL:self.file].allItems.count, 0u);
}

@end
