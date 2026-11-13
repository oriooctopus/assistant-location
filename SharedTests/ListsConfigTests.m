// Declarative config of the Lists app and its widget, read from the real files in the checkout (a
// host-less logic test has no app bundle): the URL scheme and keychain group the widget hand-off depends on,
// the identifiers that must agree between the project script, the Fastfile and the workflow.
// A mismatch in any of these only shows on a device (widget empty, tap does nothing, signing fails),
// each after a metered CI build, so they are pinned here. The widget's decode/selection code is Swift
// and SharedTests is an Objective-C-only bundle, so that logic is not covered here.
#import <XCTest/XCTest.h>

@interface ListsConfigTests : XCTestCase
@property (nonatomic, copy) NSString *root;
@end

@implementation ListsConfigTests

- (void)setUp {
    self.root = [[[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".."] stringByStandardizingPath];
}

- (NSString *)text:(NSString *)relativePath {
    NSError *error = nil;
    NSString *s = [NSString stringWithContentsOfFile:[self.root stringByAppendingPathComponent:relativePath] encoding:NSUTF8StringEncoding error:&error];
    XCTAssertNotNil(s, @"%@: %@", relativePath, error);
    return s ?: @"";
}

- (NSDictionary *)plist:(NSString *)relativePath {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self.root stringByAppendingPathComponent:relativePath]];
    XCTAssertNotNil(d, @"could not read %@", relativePath);
    return d;
}

- (void)testAppInfoPlistDeclaresTheListsUrlScheme {
    // The widget's widgetURL is lists://list/<id>; without this scheme the tap does nothing.
    NSDictionary *plist = [self plist:@"ListsApp/Info.plist"];
    XCTAssertEqualObjects(plist[@"CFBundleDisplayName"], @"Lists");
    XCTAssertEqualObjects(plist[@"CFBundlePackageType"], @"APPL");
    NSArray *schemes = plist[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"];
    XCTAssertEqualObjects(schemes, (@[@"lists"]));
    XCTAssertTrue([[self text:@"ListsWidget/ListsWidget.swift"] containsString:@"lists://list/"]);
}

- (void)testWidgetInfoPlistIsAWidgetKitExtension {
    NSDictionary *plist = [self plist:@"ListsWidget/Info.plist"];
    XCTAssertEqualObjects(plist[@"CFBundlePackageType"], @"XPC!");
    XCTAssertEqualObjects(plist[@"NSExtension"][@"NSExtensionPointIdentifier"], @"com.apple.widgetkit-extension");
    XCTAssertEqualObjects(plist[@"CFBundleVersion"], [self plist:@"ListsApp/Info.plist"][@"CFBundleVersion"], @"the widget's version must equal its host app's");
}

- (void)testAppAndWidgetShareOneKeychainGroupWrittenAndReadByTheCode {
    NSArray *group = @[@"$(AppIdentifierPrefix)com.oliverullman.lists"];
    for (NSString *path in @[@"ListsApp/Lists.entitlements", @"ListsWidget/ListsWidget.entitlements"]) {
        NSDictionary *e = [self plist:path];
        XCTAssertEqualObjects(e[@"keychain-access-groups"], group, @"%@", path);
        XCTAssertEqualObjects(e.allKeys, (@[@"keychain-access-groups"]), @"%@ must declare only the keychain group", path);
    }
    // The writer (app) and the reader (widget) must name the same resolved group, service and account.
    NSString *store = [self text:@"ListsApp/ListsStateStore.m"];
    NSString *widget = [self text:@"ListsWidget/ListsWidget.swift"];
    XCTAssertTrue([store containsString:@"@\"J66WVM2DTX.com.oliverullman.lists\""]);
    XCTAssertTrue([widget containsString:@"\"J66WVM2DTX.com.oliverullman.lists\""]);
    XCTAssertTrue([store containsString:@"kListsKeychainService = @\"com.oliverullman.lists\""]);
    XCTAssertTrue([widget containsString:@"listsKeychainService = \"com.oliverullman.lists\""]);
    XCTAssertTrue([store containsString:@"kListsKeychainAccount = @\"widget\""]);
    XCTAssertTrue([widget containsString:@"listsKeychainAccount = \"widget\""]);
    XCTAssertTrue([store containsString:@"kSecAttrAccessibleAfterFirstUnlock"], @"the widget reads while the phone is locked");
}

- (void)testAppIconIsA1024Png {
    NSString *dir = [self.root stringByAppendingPathComponent:@"ListsApp/Assets.xcassets/AppIcon.appiconset"];
    NSDictionary *contents = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"Contents.json"]] options:0 error:NULL];
    NSString *file = contents[@"images"][0][@"filename"];
    NSData *png = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:file]];
    XCTAssertGreaterThan(png.length, 24u, @"icon %@ missing", file);
    const uint8_t *b = png.bytes;
    XCTAssertEqual(memcmp(b, "\x89PNG\r\n\x1a\n", 8), 0, @"not a PNG");
    uint32_t w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    uint32_t h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    XCTAssertEqual(w, 1024u);
    XCTAssertEqual(h, 1024u);
}

- (void)testIdentifiersAgreeAcrossProjectScriptFastfileAndWorkflow {
    NSString *script = [self text:@"scripts/add_lists_app.rb"];
    NSString *fastfile = [self text:@"fastlane/Fastfile"];
    NSString *wf = [self text:@".github/workflows/ota-lists.yml"];
    XCTAssertTrue([script containsString:@"APP_ID = \"com.oliverullman.lists\""]);
    XCTAssertTrue([fastfile containsString:@"LISTS_ID = \"com.oliverullman.lists\""]);
    XCTAssertTrue([script containsString:@"EXT_ID = \"com.oliverullman.lists.widget\""]);
    XCTAssertTrue([fastfile containsString:@"LISTS_WIDGET_ID = \"#{LISTS_ID}.widget\""]);
    XCTAssertTrue([script containsString:@"PROFILE = \"Lists AdHoc\""]);
    XCTAssertTrue([fastfile containsString:@"LISTS_ADHOC_PROFILE_NAME = \"Lists AdHoc\""]);
    XCTAssertTrue([script containsString:@"EXT_PROFILE = \"Lists Widget AdHoc\""]);
    XCTAssertTrue([fastfile containsString:@"LISTS_WIDGET_ADHOC_PROFILE_NAME = \"Lists Widget AdHoc\""]);
    XCTAssertTrue([fastfile containsString:@"lane :lists_adhoc do"]);
    XCTAssertTrue([wf containsString:@"fastlane lists_adhoc"]);
    XCTAssertTrue([fastfile containsString:@"scheme: \"Lists\""]);
    // The embedded extension's target name is what the lane re-signs.
    XCTAssertTrue([script containsString:@"EXT_NAME = \"ListsWidget\""]);
    XCTAssertTrue([fastfile containsString:@"\"ListsWidget\" => LISTS_WIDGET_ADHOC_PROFILE_NAME"]);
    XCTAssertTrue([script containsString:@"\"SWIFT_OBJC_INTERFACE_HEADER_NAME\" => \"Lists-Swift.h\""]);
    XCTAssertTrue([[self text:@"ListsApp/ListsStateStore.m"] containsString:@"\"Lists-Swift.h\""]);
}

- (void)testOtaListsIsManualDispatchOnlyAndMainOtaIgnoresListsPaths {
    XCTAssertFalse([[self text:@".github/workflows/ota-lists.yml"] containsString:@"push:"], @"ota-lists is manual dispatch only");
    NSString *ota = [self text:@".github/workflows/ota.yml"];
    for (NSString *p in @[@"\"ListsApp/**\"", @"\"ListsWidget/**\"", @"\".github/workflows/ota-lists.yml\""]) {
        XCTAssertTrue([ota containsString:p], @"ota.yml paths-ignore lacks %@", p);
    }
}

@end
