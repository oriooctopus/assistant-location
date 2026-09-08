// Proves GLApiTokenAllowedForFrameURL() (Shared/GLApiTokenPolicy.h) --
// the predicate GLWebBridge.m's getApiToken handler defers to -- actually
// enforces scheme + host + PORT, not host alone. In particular: port 443 on
// the baked host must be DENIED, because that's the funnelled, public-
// internet answer for the same MagicDNS hostname the app's own web surfaces
// live on (see GLApiTokenPolicy.h's header comment). Asserts on the boolean
// predicate directly, never on log/error strings.
#import <XCTest/XCTest.h>
#import "GLApiTokenPolicy.h"

static NSString *const kTestBakedHost = @"example-host.ts.net";

@interface GLApiTokenPolicyTests : XCTestCase
@end

@implementation GLApiTokenPolicyTests

- (void)testFileURLIsAllowed {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/index.html"];
    XCTAssertTrue(GLApiTokenAllowedForFrameURL(url, kTestBakedHost));
}

- (void)testHTTPOnBakedHostAtEachAllowedPortIsAllowed {
    for (NSNumber *port in GLApiTokenAllowedPorts()) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/", kTestBakedHost, port]];
        XCTAssertTrue(GLApiTokenAllowedForFrameURL(url, kTestBakedHost), @"expected http port %@ to be allowed", port);
    }
}

- (void)testHTTPSOnBakedHostAtEachAllowedPortIsAllowed {
    for (NSNumber *port in GLApiTokenAllowedPorts()) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@:%@/", kTestBakedHost, port]];
        XCTAssertTrue(GLApiTokenAllowedForFrameURL(url, kTestBakedHost), @"expected https port %@ to be allowed", port);
    }
}

// The whole point of this predicate: :443 on the baked host is the
// Tailscale-Funnel-exposed, public-internet answer for the same MagicDNS
// hostname the app's own services live on. Host-only matching used to hand
// GL_BAKED_TOKEN to it; this must stay denied.
- (void)testPort443OnBakedHostIsDenied {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@:443/", kTestBakedHost]];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(url, kTestBakedHost));

    NSURL *urlNoExplicitPort = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/", kTestBakedHost]];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(urlNoExplicitPort, kTestBakedHost));
}

- (void)testNoExplicitPortIsDenied {
    NSURL *httpNoPort = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", kTestBakedHost]];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(httpNoPort, kTestBakedHost));

    NSURL *httpsNoPort = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/", kTestBakedHost]];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(httpsNoPort, kTestBakedHost));
}

- (void)testDifferentHostAtAllowedPortIsDenied {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://attacker.example.com:%@/", GLApiTokenAllowedPorts().firstObject]];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(url, kTestBakedHost));
}

- (void)testNonHTTPSchemeIsDenied {
    NSURL *javascriptURL = [NSURL URLWithString:@"javascript:alert(1)"];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(javascriptURL, kTestBakedHost));

    NSURL *dataURL = [NSURL URLWithString:@"data:text/html,hi"];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(dataURL, kTestBakedHost));
}

- (void)testNilOrEmptyHostIsDenied {
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(nil, kTestBakedHost));

    // "http:///path" parses to a URL with a nil host.
    NSURL *noHostURL = [NSURL URLWithString:@"http:///path"];
    XCTAssertFalse(GLApiTokenAllowedForFrameURL(noHostURL, kTestBakedHost));
}

@end
