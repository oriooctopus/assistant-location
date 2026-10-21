// Routing rules for taps in the Listen web view: off-host / non-http(s) links go to the system, same-host
// and file:// stay in-app, target=_blank always goes out.
#import <XCTest/XCTest.h>
#import "ListenLinks.h"

@interface ListenLinksTests : XCTestCase
@end

@implementation ListenLinksTests

static NSURL *U(NSString *s) { return [NSURL URLWithString:s]; }
static BOOL Tap(NSString *url) {
    return [ListenLinks shouldOpenExternally:U(url) pageURL:U(@"https://box.example:9315/") isNewWindow:NO isLinkActivation:YES];
}
static BOOL NewWin(NSString *url) {
    return [ListenLinks shouldOpenExternally:U(url) pageURL:U(@"https://box.example:9315/") isNewWindow:YES isLinkActivation:NO];
}

- (void)testOffHostHttpsTapIsExternal {
    XCTAssertTrue(Tap(@"https://example.com/article"));
    XCTAssertTrue(Tap(@"http://example.com/article"));
}

- (void)testSameHostTapStaysInApp {
    XCTAssertFalse(Tap(@"https://box.example:9315/#/queue"));
    XCTAssertFalse(Tap(@"https://BOX.example/other"));
}

- (void)testNonHttpSchemesAreExternal {
    XCTAssertTrue(Tap(@"mailto:a@b.com"));
    XCTAssertTrue(Tap(@"tel:+15551234567"));
}

- (void)testFileUrlStaysInApp {
    XCTAssertFalse(Tap(@"file:///var/mobile/shell.html"));
}

- (void)testNewWindowIsAlwaysExternalEvenSameHost {
    XCTAssertTrue(NewWin(@"https://example.com/a"));
    XCTAssertTrue(NewWin(@"https://box.example:9315/page"));
}

- (void)testNonLinkNavigationIsNeverExternal {
    XCTAssertFalse([ListenLinks shouldOpenExternally:U(@"https://example.com/") pageURL:U(@"https://box.example/")
                                         isNewWindow:NO isLinkActivation:NO]);
    XCTAssertFalse([ListenLinks shouldOpenExternally:nil pageURL:U(@"https://box.example/") isNewWindow:YES isLinkActivation:YES]);
}

@end
