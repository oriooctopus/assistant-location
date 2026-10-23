// CycleStore is plain Foundation (one JSON file, atomic writes), so these run against a real
// temp directory with no mocks.
#import <XCTest/XCTest.h>
#import "CycleStore.h"

@interface CycleStoreTests : XCTestCase
@property (nonatomic, strong) NSURL *dir;
@end

@implementation CycleStoreTests

- (void)setUp {
    self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.dir error:NULL];
}

- (CycleStore *)open {
    NSError *error = nil;
    CycleStore *store = [[CycleStore alloc] initWithDirectory:self.dir error:&error];
    XCTAssertNotNil(store, @"open failed: %@", error);
    return store;
}

- (void)testSetGetKeysDeleteRoundTrip {
    CycleStore *store = [self open];
    XCTAssertNil([store valueForKey:@"a"], @"a fresh store has no keys");
    NSError *error = nil;
    XCTAssertTrue([store setValue:@"one" forKey:@"log:1" error:&error], @"%@", error);
    XCTAssertTrue([store setValue:@"two" forKey:@"log:2" error:&error], @"%@", error);
    XCTAssertTrue([store setValue:@"cfg" forKey:@"settings" error:&error], @"%@", error);
    XCTAssertEqualObjects([store valueForKey:@"log:1"], @"one");
    XCTAssertEqualObjects([store keysWithPrefix:@"log:"], (@[@"log:1", @"log:2"]));
    XCTAssertEqualObjects([store keysWithPrefix:@""], (@[@"log:1", @"log:2", @"settings"]));
    XCTAssertTrue([store setValue:@"uno" forKey:@"log:1" error:&error], @"%@", error);
    XCTAssertEqualObjects([store valueForKey:@"log:1"], @"uno", @"set on an existing key overwrites");
    XCTAssertTrue([store setValue:nil forKey:@"log:1" error:&error], @"%@", error);
    XCTAssertNil([store valueForKey:@"log:1"]);
    XCTAssertEqualObjects([store keysWithPrefix:@"log:"], (@[@"log:2"]));
}

- (void)testValuesSurviveReopeningTheFile {
    CycleStore *store = [self open];
    NSError *error = nil;
    NSString *tricky = @"line1\nline2 \"quoted\" \\ back é 日本語 \U0001F496";
    XCTAssertTrue([store setValue:tricky forKey:@"k" error:&error], @"%@", error);
    XCTAssertTrue([store setValue:@"gone" forKey:@"d" error:&error], @"%@", error);
    XCTAssertTrue([store setValue:nil forKey:@"d" error:&error], @"%@", error);
    CycleStore *reopened = [self open];
    XCTAssertEqualObjects([reopened valueForKey:@"k"], tricky);
    XCTAssertNil([reopened valueForKey:@"d"], @"a delete must be on disk, not only in memory");
    XCTAssertEqualObjects([reopened keysWithPrefix:@""], (@[@"k"]));
}

- (void)testMalformedFileFailsLoudlyAndIsNotOverwritten {
    NSURL *file = [self.dir URLByAppendingPathComponent:@"cycle-store.json"];
    XCTAssertTrue([@"[1,2,3]" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    NSError *error = nil;
    CycleStore *store = [[CycleStore alloc] initWithDirectory:self.dir error:&error];
    XCTAssertNil(store, @"a store file that is not a JSON object must not load as empty");
    XCTAssertEqualObjects(error.domain, CycleStoreErrorDomain);
    XCTAssertEqualObjects([NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL], @"[1,2,3]");
}

- (void)testFailedWriteReportsErrorAndLeavesMemoryUnchanged {
    CycleStore *store = [self open];
    NSError *error = nil;
    XCTAssertTrue([store setValue:@"keep" forKey:@"k" error:&error], @"%@", error);
    [NSFileManager.defaultManager removeItemAtURL:self.dir error:NULL]; // the directory vanishes underneath the store
    XCTAssertFalse([store setValue:@"lost" forKey:@"k" error:&error]);
    XCTAssertEqualObjects(error.domain, CycleStoreErrorDomain);
    XCTAssertEqualObjects([store valueForKey:@"k"], @"keep", @"memory must roll back so it never disagrees with disk");
    XCTAssertFalse([store setValue:@"new" forKey:@"n" error:&error]);
    XCTAssertNil([store valueForKey:@"n"]);
}

@end
