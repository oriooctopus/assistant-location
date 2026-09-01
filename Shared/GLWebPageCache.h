// Keeps the on-disk copy of Modules/WebPages/ that managed pages load from in
// sync with events/server.py's /webpages/* routes -- see that file's header
// comment and MODULES.md's "Web pages: bundle floor + server updates"
// section for the full design. Read GLWebModuleViewController.h's doc
// comment on -initWithManagedPageNamed: first; this header is its plumbing,
// not something a module author calls directly.
//
// HEADER-ONLY (no GLWebPageCache.m), same reason GLEndpoints.h gives for its
// own single inline function: Shared/ is an individually-listed group in
// Overland.xcodeproj/project.pbxproj, not a file-system-synchronized one
// (unlike Modules/) -- a new .m here would need a manual Sources
// build-phase entry that nobody should be hand-editing into the pbxproj.
// Every symbol below is `static`, so each .m that imports this header gets
// its OWN private copy (no duplicate-symbol risk if a second file ever
// imports it) -- the same discipline GLEndpoints.h's GLEndpointURL() uses,
// just with several functions and some file-scope state instead of one.

#import <CommonCrypto/CommonCrypto.h>
#import <Foundation/Foundation.h>

#import "BakedConfig.h"

NS_ASSUME_NONNULL_BEGIN

// Same host + port as GLTheme.m's palette fetch and GLAppStateReporter.m's
// app-state POST -- events/server.py (see ~/.claude/rules/ports.md) is the
// one server every piece of "app shell infrastructure" (theme, build stamp,
// crash reports, and now the web-page asset manifest) talks to, as opposed
// to location-server:8302, which is Recents'/Tracker's own DOMAIN server.
// Web pages are cross-cutting (more.html and settings.html have nothing to
// do with location data), so they belong with the other shell-infra
// features on :8304, not bolted onto :8302. Port duplicated as its own
// static constant rather than shared via a header, same call GLTheme.m and
// GLAppStateReporter.m already made about their own copies of this exact
// port number -- three one-line constants was judged not worth sharing.
static NSInteger const kGLWebPageCacheServerPort = 8304;

static NSString *const kGLWebPageCacheDirName = @"WebPagesCache";
static NSString *const kGLWebPageCacheCurrentDirName = @"current";
static NSString *const kGLWebPageCacheStagingDirName = @"staging";

// Written inside the "current" directory alongside the downloaded files
// themselves (not NSUserDefaults) so the version this cache set was verified
// against travels with the set on disk -- if the OS purges WebPagesCache/
// under disk pressure, the version marker disappears with it and the next
// check-for-updates correctly treats that as "nothing cached, fetch fresh"
// rather than reading a stale version number for files that no longer
// exist.
static NSString *const kGLWebPageManifestVersionFileName = @".gl-manifest-version";

#pragma mark - Directory resolution

NS_INLINE NSURL *GLWebPageCacheRootDirectory(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *caches = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    return [caches URLByAppendingPathComponent:kGLWebPageCacheDirName isDirectory:YES];
}

NS_INLINE NSURL *GLWebPageCacheCurrentDirectory(void) {
    return [GLWebPageCacheRootDirectory() URLByAppendingPathComponent:kGLWebPageCacheCurrentDirName isDirectory:YES];
}

NS_INLINE NSURL *GLWebPageCacheStagingDirectory(void) {
    return [GLWebPageCacheRootDirectory() URLByAppendingPathComponent:kGLWebPageCacheStagingDirName isDirectory:YES];
}

// Locates Modules/WebPages/ INSIDE THE APP BUNDLE -- the offline floor that
// always exists, built at compile time, never touched by anything in this
// file. Tries the same two candidate layouts GLWebModuleViewController's
// -initWithBundledPageNamed: already tries for an individual resource (see
// that method's comment: Modules/ is a PBXFileSystemSynchronizedRootGroup,
// and Xcode's synchronized-group resource copying has been observed to land
// WebPages/'s contents either flat in the bundle root or nested under a
// "WebPages" subdirectory, with no compiler on this box to settle which).
// "more.html" is used as the known-good anchor file to locate the
// containing directory from, since URLForResource:withExtension: resolves a
// FILE, not a directory, and every build ships more.html unconditionally.
// Raises if neither layout can be found -- same "fail loud, not into the
// generic network-error view" reasoning -initWithBundledPageNamed: gives
// for its own raise: this is a build-config bug (Modules/'s file-system-
// synchronized group not copying .html resources), not a runtime condition
// any page's error view should be trying to explain.
NS_INLINE NSURL *GLWebPageCacheBundleDirectory(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *anchor = [bundle URLForResource:@"more" withExtension:@"html" subdirectory:@"WebPages"];
    if (anchor) {
        return [anchor URLByDeletingLastPathComponent];
    }
    anchor = [bundle URLForResource:@"more" withExtension:@"html"];
    if (anchor) {
        return [anchor URLByDeletingLastPathComponent];
    }
    [NSException raise:NSInternalInconsistencyException
                format:@"GLWebPageCache: bundled Modules/WebPages/more.html not found (checked "
                        "WebPages/ and the bundle root) -- check that Modules/'s "
                        "file-system-synchronized group is copying .html resources "
                        "into the build product"];
    return (NSURL * _Nonnull)nil; // unreached; silences a nullability warning on the raise path above
}

// A cached set only counts as usable if BOTH the directory and its version
// marker exist -- a bare directory with no marker means a previous
// GLWebPageCachePromoteVerifiedStaging() was interrupted (app killed
// mid-write) before the marker landed, which this treats identically to "no
// cache at all" rather than trusting partially-written files. The marker is
// written LAST for exactly this reason.
NS_INLINE BOOL GLWebPageCacheCurrentDirectoryIsUsable(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *current = GLWebPageCacheCurrentDirectory();
    BOOL isDir = NO;
    BOOL dirExists = [fm fileExistsAtPath:current.path isDirectory:&isDir];
    if (!dirExists || !isDir) return NO;
    NSString *versionPath = [current URLByAppendingPathComponent:kGLWebPageManifestVersionFileName].path;
    return [fm fileExistsAtPath:versionPath];
}

/// The directory to load a managed page's files FROM right now: the most
/// recently verified-good downloaded set if one exists, else the app
/// bundle's own Modules/WebPages/ directory (which always exists -- it
/// ships with every build). Never nil, never touches the network -- a plain
/// synchronous disk read, so a managed page's first paint is never held up
/// waiting for a fetch. This is what makes the bundle the offline floor:
/// with no cache and no network, this call still returns something real.
NS_INLINE NSURL *GLWebPageCacheActiveDirectory(void) {
    if (GLWebPageCacheCurrentDirectoryIsUsable()) {
        return GLWebPageCacheCurrentDirectory();
    }
    return GLWebPageCacheBundleDirectory();
}

NS_INLINE NSString *_Nullable GLWebPageCacheCurrentlyCachedVersion(void) {
    if (!GLWebPageCacheCurrentDirectoryIsUsable()) return nil;
    NSURL *versionURL = [GLWebPageCacheCurrentDirectory() URLByAppendingPathComponent:kGLWebPageManifestVersionFileName];
    return [NSString stringWithContentsOfURL:versionURL encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - Hashing + URL building

// hex-encoded sha256 of `data`, matching the "sha256:<hex>" format
// events/server.py's /webpages/manifest.json emits for each file (see that
// route's own comment for why sha256 specifically -- it's what Python's
// hashlib and CommonCrypto both do natively, no extra dependency either
// side).
NS_INLINE NSString *GLWebPageCacheSHA256Hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

// GLTheme.m's own comment on this exact pattern explains why: GLEndpointURL()
// (Shared/GLEndpoints.h) *raises* when GL_BAKED_HOST is unbaked, which is
// true for every simulator/CI build including sim-test -- building the
// string directly here instead lets an unbaked/unreachable host fail
// through NSURLSession's ordinary error path instead of crashing before a
// single frame renders.
NS_INLINE NSURL *_Nullable GLWebPageCacheServerURL(NSString *path) {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld%@",
                                                       GL_BAKED_HOST, (long)kGLWebPageCacheServerPort, path];
    return [NSURL URLWithString:urlString];
}

#pragma mark - Promotion (remove-then-move swap)

// The one filesystem operation that makes a downloaded set live: remove
// "current" (if any) and move "staging" into its place. NOT a single
// syscall-backed atomic replace -- NSFileManager's
// -replaceItemAtURL:withItemAtURL:backupItemURL:options:resultingItemURL:error:
// failed to compile against this project's SDK/deployment-target
// combination ("no visible @interface for 'NSFileManager' declares the
// selector", caught by a real `ota` build rather than assumed to work), so
// this uses two plain, universally-available calls instead.
//
// There IS a brief window between the -removeItemAtURL: and -moveItemAtURL:
// calls where GLWebPageCacheActiveDirectory() would find no usable
// "current" directory at all. That is NOT the half-written/corrupt-directory
// bug this design exists to prevent -- GLWebPageCacheActiveDirectory()'s
// fallback for exactly that case is the bundle copy, which is ALWAYS valid
// by construction (see this header's top comment on the offline floor), so
// the window degrades to "one page load reads the bundle instead of the
// cache for a moment", never a corrupted page. The version marker is still
// written INSIDE staging BEFORE any of this (not after, into current), so a
// crash between the two calls below never leaves a "current" directory that
// LOOKS usable (has a marker) but is actually the half-moved leftover of an
// interrupted promotion.
NS_INLINE void GLWebPageCachePromoteVerifiedStaging(NSURL *staging, NSString *manifestVersion) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *versionURL = [staging URLByAppendingPathComponent:kGLWebPageManifestVersionFileName];
    NSError *writeError = nil;
    if (![manifestVersion writeToURL:versionURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        NSLog(@"GLWebPageCache: could not write version marker, aborting promotion: %@", writeError);
        [fm removeItemAtURL:staging error:nil];
        return;
    }

    NSURL *current = GLWebPageCacheCurrentDirectory();
    // Ensure the cache root (current's parent) exists before -moveItemAtURL:
    // below -- first launch ever, WebPagesCache/ itself doesn't exist yet,
    // and -moveItemAtURL: requires the destination's parent to already be
    // there.
    [fm createDirectoryAtURL:GLWebPageCacheRootDirectory() withIntermediateDirectories:YES attributes:nil error:nil];

    NSError *error = nil;
    if ([fm fileExistsAtPath:current.path]) {
        if (![fm removeItemAtURL:current error:&error]) {
            NSLog(@"GLWebPageCache: could not remove old cache, aborting promotion of %@: %@", manifestVersion, error);
            [fm removeItemAtURL:staging error:nil];
            return;
        }
    }
    if (![fm moveItemAtURL:staging toURL:current error:&error]) {
        // The old set is already gone at this point (see the window this
        // function's own top comment documents) -- nothing left to roll
        // back to. GLWebPageCacheActiveDirectory() falls back to the bundle
        // until the NEXT successful check-for-updates call replaces this
        // failed attempt.
        NSLog(@"GLWebPageCache: could not move staging into place for %@: %@", manifestVersion, error);
        return;
    }
    NSLog(@"GLWebPageCache: promoted web pages to version %@", manifestVersion);
}

#pragma mark - Update check

// Downloads every file the manifest lists into a fresh staging directory,
// verifying each one's sha256 as it lands, then either promotes the whole
// set (every file verified) or discards the whole attempt (any single file
// missing/corrupt/mismatched) -- see this header's top comment on why
// atomicity is per-SET, not per-file: page.css is shared by all three
// pages, so a set with new HTML and stale CSS is exactly the bug this
// exists to prevent, and letting individual files land independently would
// risk exactly that window.
NS_INLINE void GLWebPageCacheDownloadAndVerify(NSDictionary<NSString *, NSDictionary *> *files,
                                                NSString *manifestVersion,
                                                void (^finish)(BOOL updated)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *staging = GLWebPageCacheStagingDirectory();
    // Always start from a clean staging directory -- a previous attempt
    // that crashed mid-download must not leave stray old files that could
    // be mistaken for part of THIS attempt's verified set.
    [fm removeItemAtURL:staging error:nil];
    NSError *createError = nil;
    if (![fm createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:&createError]) {
        NSLog(@"GLWebPageCache: could not create staging directory: %@", createError);
        finish(NO);
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    // Read/written from multiple download completion callbacks (arbitrary
    // background queues, one per file) -- guarded by @synchronized rather
    // than left to a group-only ordering, since two files could otherwise
    // race setting this flag with no defined winner.
    __block BOOL allVerified = YES;
    id syncToken = [NSObject new]; // dedicated lock object -- see @synchronized(syncToken) below

    for (NSString *name in files) {
        NSDictionary *fileInfo = files[name];
        NSString *expectedHash = fileInfo[@"hash"]; // "sha256:<hex>", per events/server.py's manifest route
        // Reject anything that isn't a bare filename before it ever reaches
        // a URL or a file path -- the manifest is server-controlled input,
        // and "/" or ".." here could otherwise escape the staging directory
        // (writing) or the /webpages/files/ route's own directory (reading,
        // guarded again server-side, but this is the client's own copy of
        // that same discipline).
        if (![name isKindOfClass:[NSString class]] || name.length == 0 ||
            [name containsString:@"/"] || [name containsString:@".."] ||
            ![expectedHash isKindOfClass:[NSString class]] || ![expectedHash hasPrefix:@"sha256:"]) {
            NSLog(@"GLWebPageCache: manifest entry rejected (malformed name/hash): %@", name);
            allVerified = NO;
            continue;
        }
        NSString *expectedHex = [expectedHash substringFromIndex:@"sha256:".length];

        NSURL *fileURL = GLWebPageCacheServerURL([NSString stringWithFormat:@"/webpages/files/%@", name]);
        if (!fileURL) {
            allVerified = NO;
            continue;
        }

        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithURL:fileURL
          completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error) {
            BOOL ok = NO;
            NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
            if (!error && data.length > 0 && status >= 200 && status <= 299) {
                NSString *actualHex = GLWebPageCacheSHA256Hex(data);
                if ([actualHex isEqualToString:expectedHex]) {
                    NSURL *dest = [staging URLByAppendingPathComponent:name];
                    NSError *writeError = nil;
                    ok = [data writeToURL:dest options:NSDataWritingAtomic error:&writeError];
                    if (!ok) {
                        NSLog(@"GLWebPageCache: failed writing %@ to staging: %@", name, writeError);
                    }
                } else {
                    // Loud on purpose -- a hash mismatch (truncated
                    // download, MITM, a manifest that drifted from the
                    // files it describes) must never be silently ignored,
                    // per this task's own "a hash mismatch must be loud in
                    // the log" requirement.
                    NSLog(@"GLWebPageCache: HASH MISMATCH for %@ -- expected %@, got %@ (rejecting entire update)",
                          name, expectedHex, actualHex);
                }
            } else {
                NSLog(@"GLWebPageCache: failed downloading %@ (status %ld): %@", name, (long)status, error);
            }
            @synchronized (syncToken) {
                if (!ok) allVerified = NO;
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (!allVerified) {
            NSLog(@"GLWebPageCache: update to version %@ rejected (see above) -- previous cache left in place", manifestVersion);
            [fm removeItemAtURL:staging error:nil];
            finish(NO);
            return;
        }
        GLWebPageCachePromoteVerifiedStaging(staging, manifestVersion);
        finish(YES);
    });
}

// Reentrancy guard: -loadPage (GLWebModuleViewController) calls
// GLWebPageCacheCheckForUpdates every time a managed page opens, and rapid
// tab-switching (More -> Settings -> More) could otherwise fire overlapping
// checks that both write to the SAME staging directory and corrupt each
// other's download. A plain static BOOL is enough -- every access happens
// on the main thread (this function dispatches straight back to it before
// touching the flag).
static BOOL GLWebPageCacheIsChecking = NO;

/// Kicks a background version check against the server (GET
/// /webpages/manifest.json), and if the server's version differs from the
/// currently-cached set's, downloads every file the manifest lists,
/// verifies EACH ONE's sha256 against the manifest before trusting any of
/// them, and only if the whole set verifies clean promotes it over the
/// active cache (see GLWebPageCachePromoteVerifiedStaging()'s own comment
/// for exactly how, and the tiny, harmless window that leaves). A
/// partial/corrupt download, or any single file's hash not matching,
/// discards the whole staging attempt and leaves the previously-active set
/// completely untouched.
///
/// No-ops immediately -- no network call, no completion delay -- when
/// GL_BAKED_HOST is empty or the "NO_HOST_BAKED_IN" placeholder, exactly
/// mirroring GLAppStateReporter.m's +report and GLTheme.m's palette-fetch
/// guard: this is true for every simulator/CI build (sim-test included),
/// and building the manifest URL anyway would just be one doomed DNS lookup
/// per call for a feature CI has no server to talk to.
///
/// `completion`, if given, is always called back on the main queue with
/// YES if a new set was verified and promoted, NO otherwise (already
/// current, unreachable, or a failed/corrupt download) -- never with an
/// NSError, because every failure mode here is something
/// GLWebModuleViewController silently tries again next time a managed page
/// opens, not something a caller needs to branch on today.
NS_INLINE void GLWebPageCacheCheckForUpdates(void (^_Nullable completion)(BOOL updated)) {
    // NSCAssert, not NSAssert -- this is a plain C function with no `self`/
    // `_cmd` in scope, and NSAssert's macro expansion references both
    // (it's designed for use inside an Objective-C method body). A real
    // `ota`/`sim-test` build caught this the hard way: "use of undeclared
    // identifier 'self'"/'_cmd'" at this exact line.
    NSCAssert([NSThread isMainThread], @"GLWebPageCacheCheckForUpdates: call only from the main thread");

    if (GL_BAKED_HOST.length == 0 || [GL_BAKED_HOST isEqualToString:@"NO_HOST_BAKED_IN"]) {
        if (completion) completion(NO);
        return;
    }

    if (GLWebPageCacheIsChecking) {
        if (completion) completion(NO);
        return;
    }
    GLWebPageCacheIsChecking = YES;

    void (^finish)(BOOL) = ^(BOOL updated) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GLWebPageCacheIsChecking = NO;
            if (completion) completion(updated);
        });
    };

    NSURL *manifestURL = GLWebPageCacheServerURL(@"/webpages/manifest.json");
    if (!manifestURL) {
        finish(NO);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:manifestURL
      completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error) {
        // Every failure branch below (unreachable host, non-200, malformed
        // JSON) degrades to "no update this time" rather than surfacing
        // anything -- this is a best-effort background refresh, and the
        // page the user is looking at right now already loaded from
        // GLWebPageCacheActiveDirectory() before this call was even made. A
        // one-off network hiccup must never be louder than that.
        if (error || data.length == 0) { finish(NO); return; }
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status < 200 || status > 299) { finish(NO); return; }
        NSError *jsonError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![parsed isKindOfClass:[NSDictionary class]]) { finish(NO); return; }
        NSDictionary *manifest = parsed;
        NSString *serverVersion = manifest[@"version"];
        NSDictionary *files = manifest[@"files"];
        if (![serverVersion isKindOfClass:[NSString class]] || serverVersion.length == 0 ||
            ![files isKindOfClass:[NSDictionary class]] || files.count == 0) {
            finish(NO);
            return;
        }

        NSString *cachedVersion = GLWebPageCacheCurrentlyCachedVersion();
        if (cachedVersion && [cachedVersion isEqualToString:serverVersion]) {
            finish(NO); // already up to date -- the common case on most opens
            return;
        }

        GLWebPageCacheDownloadAndVerify(files, serverVersion, finish);
    }];
    [task resume];
}

NS_ASSUME_NONNULL_END
