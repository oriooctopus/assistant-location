// GLVoiceRecordings: the file lifecycle of a Sessions voice recording against a real temp-dir GLDurableOutbox (no
// network is ever reached: nothing here flushes).
#import <XCTest/XCTest.h>
#import "GLVoiceRecordings.h"

@interface GLVoiceRecordingsTests : XCTestCase
@property (nonatomic, strong) NSURL *root;
@property (nonatomic, strong) NSURL *recordings;
@property (nonatomic, strong) GLDurableOutbox *outbox;
@end

@implementation GLVoiceRecordingsTests

- (void)setUp {
    self.root = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSString stringWithFormat:@"voice-rec-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
    self.recordings = [self.root URLByAppendingPathComponent:@"rec" isDirectory:YES];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    self.outbox = [[GLDurableOutbox alloc] initWithDirectory:[self.root URLByAppendingPathComponent:@"outbox" isDirectory:YES]
                                                  urlBuilder:^NSURL *(NSString *path) { return [NSURL URLWithString:[@"http://box.invalid" stringByAppendingString:path]]; }
                                                       token:@"tok"
                                        sessionConfiguration:config];
    self.outbox.retryInterval = 3600;
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtURL:self.root error:NULL];
}

- (NSURL *)clip:(NSString *)bytes {
    NSURL *url = [GLVoiceRecordings newRecordingURLInDirectory:self.recordings error:NULL];
    XCTAssertNotNil(url);
    XCTAssertTrue([bytes writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    return url;
}

- (void)testNewRecordingURLCreatesTheDirectoryAndIsUnique {
    NSURL *a = [GLVoiceRecordings newRecordingURLInDirectory:self.recordings error:NULL];
    NSURL *b = [GLVoiceRecordings newRecordingURLInDirectory:self.recordings error:NULL];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:self.recordings.path]);
    XCTAssertNotEqualObjects(a, b);
    XCTAssertTrue([a.lastPathComponent hasPrefix:@"session-voice-"] && [a.lastPathComponent hasSuffix:@".m4a"]);
}

- (void)testEnqueueQueuesTheAudioThenDeletesTheFile {
    NSURL *url = [self clip:@"audio-bytes"];
    NSString *itemID = [GLVoiceRecordings enqueueRecordingAtURL:url outbox:self.outbox lang:@"multi" launchId:@"L1" recovered:NO error:NULL];
    XCTAssertNotNil(itemID);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:url.path], @"deleted only after the outbox holds it");
    NSDictionary *item = [self.outbox itemWithID:itemID];
    XCTAssertEqualObjects(item[@"kind"], @"session-voice");
    XCTAssertEqualObjects(item[@"meta"][@"launchId"], @"L1");
    XCTAssertEqualObjects(item[@"meta"][@"recovered"], @NO);
    XCTAssertEqualObjects(item[@"path"], @"/sessions/transcribe?lang=multi");
}

- (void)testEmptyFileIsRefusedAndLeftAlone {
    NSURL *url = [self clip:@""];
    NSError *error = nil;
    XCTAssertNil([GLVoiceRecordings enqueueRecordingAtURL:url outbox:self.outbox lang:nil launchId:nil recovered:NO error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(self.outbox.items.count, 0u);
}

- (void)testRecoverQueuesEveryClipAsRecoveredAndDropsEmptyOnes {
    [self clip:@"one"];
    [self clip:@"two"];
    NSURL *empty = [self clip:@""];
    [@"x" writeToURL:[self.recordings URLByAppendingPathComponent:@"unrelated.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertEqual([GLVoiceRecordings recoverRecordingsInDirectory:self.recordings outbox:self.outbox], 2u);
    XCTAssertEqual(self.outbox.items.count, 2u);
    for (NSDictionary *item in self.outbox.items) {
        XCTAssertEqualObjects(item[@"kind"], @"session-voice");
        XCTAssertEqualObjects(item[@"meta"][@"recovered"], @YES);
        XCTAssertEqualObjects(item[@"path"], @"/sessions/transcribe");
    }
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:empty.path]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.recordings URLByAppendingPathComponent:@"unrelated.txt"].path]);
    XCTAssertEqual([GLVoiceRecordings recoverRecordingsInDirectory:self.recordings outbox:self.outbox], 0u, @"second sweep finds nothing");
}

- (void)testRecoverOnAMissingDirectoryIsANoOp {
    XCTAssertEqual([GLVoiceRecordings recoverRecordingsInDirectory:self.recordings outbox:self.outbox], 0u);
}

// Journal voice Save: each entry leaves the recorder for the outbox at once, so several can wait for the box together.
- (void)testJournalVoiceEntriesQueueSideBySideAndFreeTheirFiles {
    NSURL *first = [self clip:@"first-entry"];
    NSURL *second = [self clip:@"second-entry"];
    NSError *error = nil;
    NSString *a = [GLVoiceRecordings enqueueJournalVoiceAtURL:first filename:@"journal-voice-2026-11-14-090000.m4a" outbox:self.outbox error:&error];
    XCTAssertNotNil(a, @"first enqueue failed: %@", error);
    NSString *b = [GLVoiceRecordings enqueueJournalVoiceAtURL:second filename:@"journal-voice-tweet-2026-11-14-090100-walk.m4a" outbox:self.outbox error:&error];
    XCTAssertNotNil(b, @"second enqueue failed while the first was still pending: %@", error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:first.path]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:second.path]);

    NSArray<NSDictionary *> *items = self.outbox.items;
    XCTAssertEqual(items.count, 2u);
    XCTAssertEqualObjects(items[0][@"id"], a, @"oldest first");
    for (NSDictionary *item in items) {
        XCTAssertEqualObjects(item[@"kind"], @"journal-voice");
        XCTAssertEqualObjects(item[@"path"], @"/drop");
        XCTAssertEqualObjects(item[@"state"], GLDurableOutboxStatePending);
        XCTAssertEqualObjects(item[@"retryTransient"], @YES, @"a struggling box must not strand a recording as rejected");
    }
    XCTAssertEqualObjects(items[1][@"headers"][@"X-Filename"], @"journal-voice-tweet-2026-11-14-090100-walk.m4a");
    XCTAssertEqualObjects([self.outbox bodyDataForItemID:b], [@"second-entry" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testEmptyJournalVoiceIsRefusedAndLeftAlone {
    NSURL *url = [self clip:@""];
    NSError *error = nil;
    XCTAssertNil([GLVoiceRecordings enqueueJournalVoiceAtURL:url filename:@"journal-voice-x.m4a" outbox:self.outbox error:&error]);
    XCTAssertNotNil(error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:url.path]);
    XCTAssertEqual(self.outbox.items.count, 0u);
}

@end
