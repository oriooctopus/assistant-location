// GLEndpointURL(path) — the one place that turns the baked-in, path-free
// GL_BAKED_BASE_URL (GPSLogger/BakedConfig.h) into a full URL for a specific
// feature. Every feature passes its OWN explicit path; nothing derives a
// path from another feature's endpoint by string surgery.
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

/// Builds `GL_BAKED_BASE_URL + path`. Raises (never falls back) if the baked
/// base is missing/placeholder or if `path` doesn't start with "/" — a wrong
/// call here is a build-config bug, not something to silently paper over.
NS_INLINE NSURL *GLEndpointURL(NSString *path) {
    if (GL_BAKED_BASE_URL.length == 0) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GL_BAKED_BASE_URL is empty"];
    }
    if (![path hasPrefix:@"/"]) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GLEndpointURL path %@ must start with \"/\"", path];
    }
    NSURL *url = [NSURL URLWithString:[GL_BAKED_BASE_URL stringByAppendingString:path]];
    if (!url) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GL_BAKED_BASE_URL %@ + path %@ is not a valid URL",
                           GL_BAKED_BASE_URL, path];
    }
    return url;
}

NS_ASSUME_NONNULL_END
