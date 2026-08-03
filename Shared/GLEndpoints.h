// GLEndpointURL(path) — the one place that turns the baked-in, host-only
// GL_BAKED_HOST (App/BakedConfig.h) into a full URL for a specific feature
// on the location/drop server. Every feature passes its OWN explicit path;
// nothing derives a path from another feature's endpoint by string surgery.
//
// Header-only (no GLEndpoints.m): Shared/ is an individually-listed group in
// Overland.xcodeproj/project.pbxproj, not a file-system-synchronized one
// (unlike Modules/), so a new .m here would need a manual Sources
// build-phase entry that nobody should be hand-editing into the pbxproj. A
// static inline function needs no Sources entry — only the header search
// path, which already covers Shared/ for the app target.

#import <Foundation/Foundation.h>

#import "BakedConfig.h"

NS_ASSUME_NONNULL_BEGIN

/// Port for the location/drop server (see location-server, port 8302 in
/// ~/.claude/rules/ports.md). Events (8304) and Todos (8308) are separate
/// servers and build their own URL directly from GL_BAKED_HOST instead of
/// going through this helper.
static NSInteger const kGLBakedHostPort = 8302;

/// Builds `http://GL_BAKED_HOST:8302 + path`. Raises (never falls back) if
/// the baked host is missing/placeholder or if `path` doesn't start with
/// "/" — a wrong call here is a build-config bug, not something to silently
/// paper over.
NS_INLINE NSURL *GLEndpointURL(NSString *path) {
    if (GL_BAKED_HOST.length == 0 || [GL_BAKED_HOST isEqualToString:@"NO_HOST_BAKED_IN"]) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GL_BAKED_HOST is empty or unbaked"];
    }
    if (![path hasPrefix:@"/"]) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GLEndpointURL path %@ must start with \"/\"", path];
    }
    NSString *baseURL = [NSString stringWithFormat:@"http://%@:%ld", GL_BAKED_HOST, (long)kGLBakedHostPort];
    NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingString:path]];
    if (!url) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"%@ + path %@ is not a valid URL", baseURL, path];
    }
    return url;
}

NS_ASSUME_NONNULL_END
