// Proves GLDropUploader (Shared/) stages more than stills and videos: the
// share extension used to classify every item as "movie or else image", so a
// Voice Memo (com.apple.m4a-audio) fell into the image branch, failed the
// public.image file load, and then failed the UIImage salvage -- the user saw
// "could not read image" for a recording. These tests build real
// NSItemProviders around real temp files and assert on the staged result
// (bytes, name, content type), never on log strings.
#import <XCTest/XCTest.h>
#import "GLDropUploader.h"

@interface GLDropUploaderTests : XCTestCase
@end

@implementation GLDropUploaderTests

#pragma mark - Helpers

/// A temp file with the given name and contents. The extension is what
/// -[NSItemProvider initWithContentsOfURL:] derives the registered UTI from.
- (NSURL *)tempFileNamed:(NSString *)name bytes:(NSUInteger)count {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:NULL];
    NSURL *url = [dir URLByAppendingPathComponent:name];
    NSMutableData *data = [NSMutableData dataWithLength:count];
    // Non-zero bytes so a truncated or zeroed copy can't pass by accident.
    uint8_t *p = data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) p[i] = (uint8_t)(i * 31 + 7);
    XCTAssertTrue([data writeToURL:url atomically:YES]);
    return url;
}

/// A provider that only ever vends a file URL (what the Files app and mail
/// attachments hand to a share extension), typed as nothing more specific.
- (NSItemProvider *)fileURLProviderFor:(NSURL *)url {
    return [[NSItemProvider alloc] initWithItem:url typeIdentifier:@"public.file-url"];
}

typedef void (^GLDropStagedAssertions)(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error);

- (void)loadProvider:(NSItemProvider *)provider index:(NSUInteger)index assert:(GLDropStagedAssertions)assertions {
    XCTestExpectation *done = [self expectationWithDescription:@"load"];
    [GLDropUploader loadItemFromProvider:provider
                                   index:index
                              completion:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        assertions(fileURL, filename, contentType, error);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:10];
}

/// A provider whose file representation for `type` always fails, reporting
/// `sentinel` as the underlying error's localized description -- so a test
/// can assert the failure that comes back names its own type, not a
/// different branch's generic message.
- (NSItemProvider *)failingProviderOfType:(NSString *)type sentinel:(NSString *)sentinel {
    NSItemProvider *provider = [[NSItemProvider alloc] init];
    [provider registerFileRepresentationForTypeIdentifier:type
                                              fileOptions:0
                                               visibility:NSItemProviderRepresentationVisibilityAll
                                              loadHandler:^NSProgress *(void (^completionHandler)(NSURL *, BOOL, NSError *)) {
        completionHandler(nil, NO,
                           [NSError errorWithDomain:@"test"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey : sentinel}]);
        return nil;
    }];
    return provider;
}

#pragma mark - Classification

- (void)testM4AIsAudioNotImageOrMovie {
    NSURL *url = [self tempFileNamed:@"New Recording 3.m4a" bytes:64];
    NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindAudio);
    XCTAssertTrue([GLDropUploader providerIsSupported:provider]);
}

- (void)testAudioTypeRegisteredDirectlyIsAudio {
    // Voice Memos registers the concrete m4a type, not public.audio itself;
    // classification must go through conformance, not string equality.
    NSItemProvider *provider = [[NSItemProvider alloc] initWithItem:[NSData data]
                                                     typeIdentifier:@"com.apple.m4a-audio"];
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindAudio);
}

- (void)testImageAndMovieStayThemselves {
    NSItemProvider *jpeg = [[NSItemProvider alloc] initWithItem:[NSData data] typeIdentifier:@"public.jpeg"];
    NSItemProvider *mov = [[NSItemProvider alloc] initWithItem:[NSData data] typeIdentifier:@"com.apple.quicktime-movie"];
    XCTAssertEqual([GLDropUploader kindOfProvider:jpeg], GLDropKindImage);
    XCTAssertEqual([GLDropUploader kindOfProvider:mov], GLDropKindMovie);
}

- (void)testImageSharedAsFileURLIsStillAnImage {
    // A PNG from the Files app conforms to public.image AND public.file-url;
    // the image branch (with its JPEG salvage path) must win. Built
    // explicitly as a dual-typed provider rather than via
    // initWithContentsOfURL:, since that method's exact registered types are
    // an implementation detail this test shouldn't depend on.
    NSItemProvider *provider = [[NSItemProvider alloc] init];
    NSURL *url = [self tempFileNamed:@"shot.png" bytes:64];
    [provider registerFileRepresentationForTypeIdentifier:@"public.png"
                                              fileOptions:0
                                               visibility:NSItemProviderRepresentationVisibilityAll
                                              loadHandler:^NSProgress *(void (^completionHandler)(NSURL *, BOOL, NSError *)) {
        completionHandler(url, NO, nil);
        return nil;
    }];
    [provider registerItemForTypeIdentifier:@"public.file-url"
                                loadHandler:^(NSItemProviderCompletionHandler completionHandler, Class expectedValueClass, NSDictionary *options) {
        completionHandler((id<NSSecureCoding>)url, nil);
    }];
    XCTAssertTrue([provider hasItemConformingToTypeIdentifier:@"public.file-url"],
                  @"premise: provider must actually be dual-typed for this test to mean anything");
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindImage);
}

- (void)testImageAndMovieTogetherIsAnImage {
    // Pins the image-first precedence from a different angle: a provider
    // typed as both a movie and an image classifies as an image.
    NSItemProvider *provider = [[NSItemProvider alloc] init];
    [provider registerDataRepresentationForTypeIdentifier:@"com.apple.quicktime-movie"
                                                visibility:NSItemProviderRepresentationVisibilityAll
                                                loadHandler:^NSProgress *(void (^completionHandler)(NSData *, NSError *)) {
        completionHandler([NSData data], nil);
        return nil;
    }];
    [provider registerDataRepresentationForTypeIdentifier:@"public.jpeg"
                                                visibility:NSItemProviderRepresentationVisibilityAll
                                                loadHandler:^NSProgress *(void (^completionHandler)(NSData *, NSError *)) {
        completionHandler([NSData data], nil);
        return nil;
    }];
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindImage);
}

- (void)testPlainFileURLIsAGenericFile {
    NSURL *url = [self tempFileNamed:@"notes.pdf" bytes:64];
    XCTAssertEqual([GLDropUploader kindOfProvider:[self fileURLProviderFor:url]], GLDropKindFile);
}

- (void)testContentTypedDocumentIsAGenericFile {
    // The Files app types a PDF as com.adobe.pdf, not as a file URL.
    NSURL *url = [self tempFileNamed:@"notes.pdf" bytes:64];
    NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindFile);
    NSItemProvider *zip = [[NSItemProvider alloc] initWithItem:[NSData data] typeIdentifier:@"public.zip-archive"];
    XCTAssertEqual([GLDropUploader kindOfProvider:zip], GLDropKindFile);
}

- (void)testContentTypedDocumentIsStagedByteForByte {
    NSURL *url = [self tempFileNamed:@"notes.pdf" bytes:3000];
    NSData *original = [NSData dataWithContentsOfURL:url];
    NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
    // initWithContentsOfURL: does not set suggestedName on its own (the
    // simulator's vended temp file is named after the UTI, not the item), so
    // tests model what Files/Voice Memos actually send by setting it explicitly.
    provider.suggestedName = @"notes.pdf";
    [self loadProvider:provider index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(error);
        XCTAssertEqualObjects(filename, @"notes.pdf");
        XCTAssertEqualObjects(contentType, @"application/pdf");
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:fileURL], original);
    }];
}

- (void)testWebURLAndTextSnippetAreUnsupported {
    NSItemProvider *web = [[NSItemProvider alloc] initWithItem:[NSURL URLWithString:@"https://example.com/"]
                                                typeIdentifier:@"public.url"];
    NSItemProvider *text = [[NSItemProvider alloc] initWithItem:@"hello" typeIdentifier:@"public.plain-text"];
    XCTAssertEqual([GLDropUploader kindOfProvider:web], GLDropKindUnsupported);
    XCTAssertEqual([GLDropUploader kindOfProvider:text], GLDropKindUnsupported);
    XCTAssertFalse([GLDropUploader providerIsSupported:web]);
    XCTAssertFalse([GLDropUploader providerIsSupported:text]);
}

#pragma mark - Staging

- (void)testAudioRecordingIsStagedByteForByteWithItsOwnName {
    NSURL *url = [self tempFileNamed:@"New Recording 3.m4a" bytes:4096];
    NSData *original = [NSData dataWithContentsOfURL:url];
    NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
    // No extension on suggestedName here, on purpose: proves the extension
    // gets appended from the vended file's own URL when the name alone
    // doesn't carry one -- suggestedName without an extension is what Voice
    // Memos actually sends.
    provider.suggestedName = @"New Recording 3";
    [self loadProvider:provider index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(error);
        XCTAssertEqualObjects(filename, @"New Recording 3.m4a");
        XCTAssertEqualObjects(contentType, @"audio/mp4");
        XCTAssertNotNil(fileURL);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:fileURL], original);
        // Staged into our own temp dir, not the provider's vended location.
        XCTAssertNotEqualObjects(fileURL.path, url.path);
    }];
}

- (void)testAudioWithNoSuggestedNameFallsBackToVendedName {
    // When the provider carries no suggestedName at all, filenameForURL: must
    // fall back to the vended file's own name -- whatever the simulator
    // actually calls it -- rather than crash or produce a nil/empty name.
    // The exact "Apple MPEG-4 audio.m4a"-style description string isn't
    // pinned since it's simulator/OS-version dependent; only the extension is.
    NSURL *url = [self tempFileNamed:@"New Recording 3.m4a" bytes:4096];
    NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
    [self loadProvider:provider index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(error);
        XCTAssertNotNil(filename);
        XCTAssertEqualObjects(filename.pathExtension.lowercaseString, @"m4a");
        XCTAssertEqualObjects(contentType, @"audio/mp4");
    }];
}

- (void)testGenericFileIsStagedByteForByteWithItsOwnName {
    NSURL *url = [self tempFileNamed:@"report final.pdf" bytes:2048];
    NSData *original = [NSData dataWithContentsOfURL:url];
    [self loadProvider:[self fileURLProviderFor:url] index:2 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(error);
        XCTAssertEqualObjects(filename, @"report final.pdf");
        XCTAssertEqualObjects(contentType, @"application/pdf");
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:fileURL], original);
    }];
}

- (void)testUnreadableAudioFailsInsteadOfBecomingAnImage {
    // An audio provider that cannot vend a file must report its own error --
    // the pre-fix code fell through to the UIImage salvage path here and
    // reported "could not read image" for a recording.
    NSItemProvider *provider = [self failingProviderOfType:@"com.apple.m4a-audio" sentinel:@"AUDIO-SENTINEL"];
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindAudio);
    [self loadProvider:provider index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(fileURL);
        XCTAssertNil(filename);
        XCTAssertEqualObjects(error, @"AUDIO-SENTINEL");
    }];
}

- (void)testUnreadableMovieReportsItsOwnError {
    NSItemProvider *provider = [self failingProviderOfType:@"com.apple.quicktime-movie" sentinel:@"MOVIE-SENTINEL"];
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindMovie);
    [self loadProvider:provider index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(fileURL);
        XCTAssertEqualObjects(error, @"MOVIE-SENTINEL");
    }];
}

- (void)testUnreadableDocumentReportsItsOwnError {
    NSItemProvider *provider = [self failingProviderOfType:@"com.adobe.pdf" sentinel:@"PDF-SENTINEL"];
    XCTAssertEqual([GLDropUploader kindOfProvider:provider], GLDropKindFile);
    [self loadProvider:provider index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(fileURL);
        XCTAssertEqualObjects(error, @"PDF-SENTINEL");
    }];
}

- (void)testUnsupportedItemFailsWithoutStaging {
    NSItemProvider *web = [[NSItemProvider alloc] initWithItem:[NSURL URLWithString:@"https://example.com/"]
                                                typeIdentifier:@"public.url"];
    [self loadProvider:web index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(fileURL);
        XCTAssertEqualObjects(error, @"unsupported item");
    }];
}

- (void)testStagedFileSurvivesTheVendBlock {
    // The provider's vended URL is only valid for the lifetime of its
    // completion block; this proves the staged copy still has real bytes
    // once that block -- and loadProvider:'s wait for it -- has returned.
    NSURL *url = [self tempFileNamed:@"New Recording 3.m4a" bytes:4096];
    NSData *original = [NSData dataWithContentsOfURL:url];
    NSItemProvider *provider = [[NSItemProvider alloc] initWithContentsOfURL:url];
    __block NSURL *staged = nil;
    [self loadProvider:provider index:0 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(error);
        staged = fileURL;
    }];
    XCTAssertNotNil(staged);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:staged], original);
}

- (void)testNamelessAudioGetsNumberedRecordingName {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:NULL];
    NSURL *url = [dir URLByAppendingPathComponent:@"blob"];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToURL:url atomically:YES]);

    NSItemProvider *provider = [[NSItemProvider alloc] init];
    [provider registerFileRepresentationForTypeIdentifier:@"com.apple.m4a-audio"
                                              fileOptions:0
                                               visibility:NSItemProviderRepresentationVisibilityAll
                                              loadHandler:^NSProgress *(void (^completionHandler)(NSURL *, BOOL, NSError *)) {
        completionHandler(url, NO, nil);
        return nil;
    }];
    [self loadProvider:provider index:2 assert:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
        XCTAssertNil(error);
        XCTAssertEqualObjects(filename, @"recording-3.m4a");
        XCTAssertEqualObjects(contentType, @"audio/mp4");
    }];
}

#pragma mark - Content type

- (void)testContentTypeTable {
    NSDictionary *cases = @{
        @"a.m4a" : @"audio/mp4",
        @"a.MP3" : @"audio/mpeg",
        @"a.wav" : @"audio/wav",
        @"a.mov" : @"video/quicktime",
        @"a.mp4" : @"video/mp4",
        @"a.heic" : @"image/heic",
        @"a.png" : @"image/png",
        @"a.PDF" : @"application/pdf",
        @"a.zip" : @"application/zip",
        @"a.txt" : @"text/plain",
        @"IMG_0001.jpg" : @"image/jpeg",
        @"a.jpeg" : @"image/jpeg",
        @"archive.tar.gz" : @"application/octet-stream",
        @"a.xyzzy" : @"application/octet-stream",
        @"noext" : @"application/octet-stream",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *expected, BOOL *stop) {
        XCTAssertEqualObjects([GLDropUploader contentTypeForFilename:name], expected, @"%@", name);
    }];
}

@end
