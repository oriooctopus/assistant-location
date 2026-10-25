// Pins the background /drop upload (Shared/GLDropBackground.m): the session is
// a real background session scoped to the App Group, uploads are fromFile:
// out of the group container, every failed file produces exactly ONE
// notification with the agreed wording, success is silent, and both targets'
// entitlements list the same group (the OS refuses a sharedContainerIdentifier
// the process is not entitled to, and only at runtime on a device).
#import <XCTest/XCTest.h>
#import "GLDropBackground.h"

@interface GLDropBackgroundTests : XCTestCase
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *posted;
@property(nonatomic, strong) GLDropBackground *drop;
@end

@implementation GLDropBackgroundTests

- (void)setUp {
    self.root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:NULL];
    self.posted = [NSMutableArray array];
    self.drop = [[GLDropBackground alloc] initWithIdentifier:
        [GLDropSessionIdentifierPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.drop.stagingRoot = self.root;
    __weak __typeof(self) weak = self;
    self.drop.notifier = ^(NSString *identifier, NSString *title, NSString *body, void (^done)(void)) {
        [weak.posted addObject:@{@"id": identifier, @"title": title, @"body": body}];
        done();
    };
}

- (NSURL *)stagedFile:(NSString *)name taskDescription:(NSString **)description {
    NSURL *src = [self.root URLByAppendingPathComponent:@"incoming.tmp"];
    [[@"payload" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:src atomically:YES];
    NSString *error = nil;
    NSURL *staged = [GLDropBackground moveFileAtURL:src filename:name toRoot:self.root taskDescription:description error:&error];
    XCTAssertNotNil(staged, @"%@", error);
    return staged;
}

- (NSHTTPURLResponse *)responseWithStatus:(NSInteger)status {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://h:8302/drop"]
                                       statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil];
}

#pragma mark - Session configuration

- (void)testConfigurationIsBackgroundAndScopedToTheAppGroup {
    NSURLSessionConfiguration *config = [GLDropBackground configurationWithIdentifier:@"com.oliverullman.assistantlocation.drop.x"];
    XCTAssertEqualObjects(config.identifier, @"com.oliverullman.assistantlocation.drop.x");
    XCTAssertEqualObjects(config.sharedContainerIdentifier, @"group.com.oliverullman.assistantlocation");
    XCTAssertTrue(config.sessionSendsLaunchEvents);
    XCTAssertFalse(config.discretionary, @"a user-initiated share must not wait for wifi+power");
}

- (void)testSessionIdentifiersAreUniqueAndRecognised {
    GLDropBackground *a = [GLDropBackground newUploadSession];
    GLDropBackground *b = [GLDropBackground newUploadSession];
    XCTAssertNotEqualObjects(a.identifier, b.identifier);
    XCTAssertTrue([GLDropBackground ownsSessionIdentifier:a.identifier]);
    XCTAssertFalse([GLDropBackground ownsSessionIdentifier:@"com.oliverullman.assistantlocation.todo-outbox"]);
}

- (void)testUploadIsAFromFileTaskOnABackgroundSession {
    NSString *description = nil;
    NSURL *staged = [self stagedFile:@"IMG_1234.JPG" taskDescription:&description];
    NSURLSessionUploadTask *task = [self.drop uploadStagedFileAtURL:staged
                                                    taskDescription:description
                                                        contentType:@"image/jpeg"
                                                         toEndpoint:@"http://127.0.0.1:1/drop"
                                                              token:@"t"
                                                           progress:nil
                                                         completion:nil];
    XCTAssertTrue([task isKindOfClass:[NSURLSessionUploadTask class]]);
    XCTAssertEqualObjects(self.drop.session.configuration.identifier, self.drop.identifier);
    XCTAssertEqualObjects(self.drop.session.configuration.sharedContainerIdentifier, GLDropAppGroup);
    XCTAssertEqualObjects(task.taskDescription, description);
    XCTAssertEqualObjects(task.originalRequest.allHTTPHeaderFields[@"X-Filename"], @"IMG_1234.JPG");
    XCTAssertNil(task.originalRequest.HTTPBody, @"the body must come from the file");
    [task cancel];
    [self.drop.session invalidateAndCancel];
}

#pragma mark - Staging

- (void)testStagedFileLivesUnderTheStagingRootWithItsOwnName {
    NSString *description = nil;
    NSURL *staged = [self stagedFile:@"IMG_1234.JPG" taskDescription:&description];
    XCTAssertTrue([staged.path hasPrefix:self.root.path]);
    XCTAssertEqualObjects(staged.lastPathComponent, @"IMG_1234.JPG");
    XCTAssertEqualObjects(description, ([NSString stringWithFormat:@"%@/IMG_1234.JPG", staged.URLByDeletingLastPathComponent.lastPathComponent]));
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:staged], [@"payload" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testSlashInFilenameCannotEscapeTheStagingDirectory {
    NSString *description = nil;
    NSURL *staged = [self stagedFile:@"a/b.jpg" taskDescription:&description];
    XCTAssertEqualObjects(staged.lastPathComponent, @"a_b.jpg");
}

- (void)testEntitlementsAreRequiredForTheRealContainer {
    // In this host-less bundle the group container is unavailable (no
    // entitlement); the API must say so with nil rather than a bogus path.
    NSURL *root = GLDropBackground.defaultStagingRoot;
    if (root) XCTAssertTrue([root.path containsString:@"GLDropStaging"]);
}

#pragma mark - Failure -> notification mapping

- (void)testConnectionLostPostsOneNotificationWithTheDocumentedWording {
    NSError *lost = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil];
    [self.drop finishTaskWithDescription:@"uuid1/IMG_1234.JPG" response:nil error:lost completion:nil];
    XCTAssertEqual(self.posted.count, 1u);
    XCTAssertEqualObjects(self.posted[0][@"title"], @"Upload failed");
    XCTAssertEqualObjects(self.posted[0][@"body"], @"IMG_1234.JPG: connection lost");
}

- (void)testNon2xxStatusesCountAsFailures {
    for (NSNumber *status in @[@301, @400, @401, @413, @500, @503]) {
        [self.posted removeAllObjects];
        [self.drop finishTaskWithDescription:@"u/f.jpg" response:[self responseWithStatus:status.integerValue] error:nil completion:nil];
        XCTAssertEqual(self.posted.count, 1u, @"HTTP %@ must notify", status);
        XCTAssertTrue([self.posted[0][@"body"] containsString:@"f.jpg"]);
        XCTAssertTrue([self.posted[0][@"body"] containsString:status.stringValue], @"%@", self.posted[0][@"body"]);
    }
}

- (void)testSuccessIsSilent {
    for (NSNumber *status in @[@200, @201, @204, @299]) {
        [self.drop finishTaskWithDescription:@"u/f.jpg" response:[self responseWithStatus:status.integerValue] error:nil completion:nil];
    }
    XCTAssertEqual(self.posted.count, 0u);
}

- (void)testTwoFailedFilesPostTwoNotificationsWithDistinctIdentifiers {
    NSError *lost = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil];
    [self.drop finishTaskWithDescription:@"u1/a.jpg" response:nil error:lost completion:nil];
    [self.drop finishTaskWithDescription:@"u2/b.jpg" response:nil error:lost completion:nil];
    [self.drop finishTaskWithDescription:@"u3/c.jpg" response:[self responseWithStatus:200] error:nil completion:nil];
    XCTAssertEqual(self.posted.count, 2u);
    XCTAssertNotEqualObjects(self.posted[0][@"id"], self.posted[1][@"id"]);
}

- (void)testCompletionReceivesFilenameAndReason {
    XCTestExpectation *done = [self expectationWithDescription:@"completion"];
    [self.drop finishTaskWithDescription:@"u/x.mov" response:[self responseWithStatus:500] error:nil
                              completion:^(NSString *filename, NSString *reason) {
        XCTAssertEqualObjects(filename, @"x.mov");
        XCTAssertEqualObjects(reason, @"server returned HTTP 500");
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:5];
}

- (void)testStagedFileIsDeletedWhenTheTaskFinishes {
    NSString *description = nil;
    NSURL *staged = [self stagedFile:@"IMG_1.JPG" taskDescription:&description];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:staged.path]);
    [self.drop finishTaskWithDescription:description response:[self responseWithStatus:200] error:nil completion:nil];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:staged.path]);
}

- (void)testBodyFormat {
    XCTAssertEqualObjects([GLDropBackground notificationBodyForFilename:@"IMG_1234.JPG" reason:@"connection lost"],
                          @"IMG_1234.JPG: connection lost");
}

#pragma mark - Entitlements

- (NSArray *)groupsInEntitlements:(NSString *)relativePath {
    NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
    NSString *path = [[here stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    XCTAssertNotNil(plist, @"could not read %@", path);
    return plist[@"com.apple.security.application-groups"];
}

- (void)testAppAndExtensionEntitlementsListTheSameAppGroupTheCodeUses {
    NSArray *app = [self groupsInEntitlements:@"../Overland.entitlements"];
    NSArray *ext = [self groupsInEntitlements:@"../ShareToDesktop/ShareToDesktop.entitlements"];
    XCTAssertTrue([app containsObject:GLDropAppGroup], @"app groups: %@", app);
    XCTAssertTrue([ext containsObject:GLDropAppGroup], @"extension groups: %@", ext);
}

- (void)testExtensionEntitlementsKeepTheShareKeychainGroup {
    NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
        [[here stringByAppendingPathComponent:@"../ShareToDesktop/ShareToDesktop.entitlements"] stringByStandardizingPath]];
    XCTAssertEqualObjects(plist[@"keychain-access-groups"],
                          @[@"$(AppIdentifierPrefix)com.oliverullman.assistantlocation.share"]);
}

- (void)testExtensionTargetUsesItsEntitlementsFile {
    NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
    NSString *pbx = [NSString stringWithContentsOfFile:
        [[here stringByAppendingPathComponent:@"../Overland.xcodeproj/project.pbxproj"] stringByStandardizingPath]
                                              encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertNotNil(pbx);
    NSUInteger n = [[pbx componentsSeparatedByString:@"CODE_SIGN_ENTITLEMENTS = ShareToDesktop/ShareToDesktop.entitlements;"] count] - 1;
    XCTAssertEqual(n, 2u, @"Debug and Release of the extension must both sign with it");
}

@end
