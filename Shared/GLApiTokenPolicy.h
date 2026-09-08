// GLApiTokenAllowedForFrameURL() -- the one place that decides whether a
// WKWebView frame gets handed GL_BAKED_TOKEN (see
// Modules/WebBridge/GLWebBridge.m's getApiToken handling). Pulled out of
// GLWebBridge.m into a header-only predicate so SharedTests can exercise it
// directly with no WebKit, no WKScriptMessage, no host app -- see
// GLApiTokenPolicyTests.m.
//
// Header-only (no GLApiTokenPolicy.m), same reasoning as GLEndpoints.h's own
// header comment: Shared/ is an individually-listed group in
// Overland.xcodeproj/project.pbxproj, not a file-system-synchronized one, so
// a new .m here would need a manual Sources build-phase entry that nobody
// should be hand-editing into the pbxproj. A static inline function needs
// only the header search path, which every target that needs this already
// has (it already resolves "GLEndpoints.h" etc the same way).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Every port this app actually serves a web surface on: 8212 Finances, 8302
/// location/drop, 8304 events/theme/crash/appstate, 8308 todo-sorter over
/// plain HTTP, 9308 todo-sorter over HTTPS, 8312 Growth.
///
/// Deliberately excludes 443/8443/10000: once the Todos tab moved to the
/// tailnet's MagicDNS name, that single hostname also answers on :443 with
/// Tailscale Funnel ON (i.e. the public internet) plus other serve ports
/// carrying unrelated content. GLApiTokenAllowedForFrameURL() below matches
/// this port list, not just scheme + host, because host-only matching would
/// hand GL_BAKED_TOKEN to any page on any of those.
NS_INLINE NSArray<NSNumber *> *GLApiTokenAllowedPorts(void) {
    static NSArray<NSNumber *> *ports;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ports = @[@8212, @8302, @8304, @8308, @9308, @8312]; });
    return ports;
}

/// True if `frameURL` should be handed GL_BAKED_TOKEN: either a local
/// `file://` page, or an http(s) page on `bakedHost` at one of
/// GLApiTokenAllowedPorts(). `frameURL` with no explicit port (i.e. the
/// scheme's default, 80/443) is never one of ours -- :443 in particular is
/// exactly the funnelled public one -- so a missing port is a denial rather
/// than something to guess a default for. `frameURL` nil, or with a nil/
/// empty host, is denied.
NS_INLINE BOOL GLApiTokenAllowedForFrameURL(NSURL *_Nullable frameURL, NSString *bakedHost) {
    if (frameURL.isFileURL) return YES;
    NSString *scheme = frameURL.scheme.lowercaseString;
    BOOL isHTTPFamily = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    BOOL isBakedHost = frameURL.host.length > 0 && bakedHost.length > 0 && [frameURL.host isEqualToString:bakedHost];
    // TEMP: revert-proof for GLApiTokenPolicyTests -- accept any port. If
    // testPort443OnBakedHostIsDenied doesn't fail with this in place, the
    // test isn't actually checking the port. Restore the allowlist check
    // before merging.
    BOOL isAllowedPort = YES;
    return isHTTPFamily && isBakedHost && isAllowedPort;
}

NS_ASSUME_NONNULL_END
