// Pure-logic tests for ListenDownloads: URL -> local path mapping and the reject
// rules for the `download` bridge payload.
#import <XCTest/XCTest.h>
#import "ListenDownloads.h"

@interface ListenDownloadsTests : XCTestCase
@end

@implementation ListenDownloadsTests

static NSString *Rel(NSString *s) { return [ListenDownloads relativePathForURL:[NSURL URLWithString:s]]; }

- (void)testPathMirrorsUrlPath {
    XCTAssertEqualObjects(Rel(@"http://host:8315/audio/abc/tts/12-clear.mp3"), @"audio/abc/tts/12-clear.mp3");
    XCTAssertEqualObjects(Rel(@"https://h/audio/abc/original.mp3?x=1"), @"audio/abc/original.mp3");
    XCTAssertEqualObjects(Rel(@"https://h/listen-guest/audio/abc/original.mp3"), @"audio/abc/original.mp3", @"one path prefix");
    NSURL *root = [NSURL fileURLWithPath:@"/tmp/root" isDirectory:YES];
    XCTAssertEqualObjects([ListenDownloads fileURLForRelativePath:@"audio/abc/o.mp3" root:root].path, @"/tmp/root/audio/abc/o.mp3");
}

- (void)testRejectsOutsideAudioTraversalAndBadScheme {
    XCTAssertNil(Rel(@"http://h/other/abc/x.mp3"), @"not under /audio/");
    XCTAssertNil(Rel(@"http://h/a/b/audio/abc/x.mp3"), @"only one prefix segment");
    XCTAssertNil(Rel(@"http://h/listen-guest/audio/../x.mp3"), @".. under a prefix");
    XCTAssertNil(Rel(@"http://h/audio/abc"), @"no file component");
    XCTAssertNil(Rel(@"http://h/audio/../etc/passwd"), @"..");
    XCTAssertNil(Rel(@"http://h/audio/abc/%2e%2e/x.mp3"), @"encoded ..");
    XCTAssertNil(Rel(@"file:///audio/abc/x.mp3"), @"file scheme");
}

- (void)testValidateItems {
    XCTAssertNil(([ListenDownloads validateItems:@[@{@"itemId": @"a", @"urls": @[@"http://h/audio/a/x.mp3"]}]]));
    XCTAssertNil([ListenDownloads validateItems:@[]], @"empty list clears everything");
    XCTAssertNotNil([ListenDownloads validateItems:@"x"], @"not an array");
    XCTAssertNotNil(([ListenDownloads validateItems:@[@{@"itemId": @"", @"urls": @[]}]]), @"empty itemId");
    XCTAssertNotNil(([ListenDownloads validateItems:@[@{@"itemId": @"a"}]]), @"missing urls");
    XCTAssertNotNil(([ListenDownloads validateItems:@[@{@"itemId": @"a", @"urls": @[@5]}]]), @"non-string url");
    XCTAssertNotNil(([ListenDownloads validateItems:@[@{@"itemId": @"a", @"urls": @[@"http://h/audio/../x.mp3"]}]]), @"traversal");
}

@end
