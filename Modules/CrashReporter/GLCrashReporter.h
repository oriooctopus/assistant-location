// Catches uncaught exceptions and gets a report of them to the server, on
// the NEXT launch -- built to chase the Events-tile crash on Oliver's real
// phone (iOS 26.5) that a sim-test on the only iOS runtime CI has (26.2)
// could NOT reproduce (UITEST_MORE_TILE_TAP passed clean there), so we have
// no exception text at all today. Same blind spot GLAppStateReporter.h
// documents for theme state, applied to crashes: nothing about a real crash
// reaches this box unless Oliver digs an .ips file out of iOS Settings by
// hand, which is the fallback this whole feature exists to avoid.
//
// Two halves, deliberately split across two launches:
//
// 1. -installHandler installs NSSetUncaughtExceptionHandler. When it fires,
//    the process is already unwinding to a crash -- see GLCrashReporter.m's
//    header comment on the handler for exactly why that means synchronous
//    local disk I/O ONLY, no network call and no @try/@catch. The report is
//    written to a file in Application Support and left there.
//
// 2. +reportPendingCrashIfAny, called on the NEXT launch (a crash always
//    ends the process, so "next launch" is the earliest safe point to try
//    sending it), reads that file if present, POSTs it to the server's
//    /api/crash-report, and deletes it only on a successful (2xx) response
//    -- a failed send (no network, server down) leaves it for the launch
//    after that to retry, same fire-and-forget-but-not-lossy shape as
//    GLAppStateReporter.
//
// Breadcrumbs: a small in-memory ring buffer that GLWebBridge and
// GLModuleRegistry append to at the points that matter for the Events-tile
// bug specifically (bridge method dispatch, +openOverflowModuleWithIdentifier:,
// +openModuleViewController:ontoNavigationController:'s branch choice) -- see
// GLCrashReporter.m and those two files for the exact call sites. Persisted
// alongside the crash report so a report says not just THAT the app died but
// roughly WHERE, which plain callStackSymbols often can't (a crash inside
// UIKit/WebKit's own frames points at the framework, not at which of OUR
// code paths called into it).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLCrashReporter : NSObject

/// Installs NSSetUncaughtExceptionHandler. Call exactly once, as EARLY as
/// possible in app startup (App/AppDelegate.m's very first line of
/// -application:didFinishLaunchingWithOptions:) -- before GLTheme,
/// GLModuleRegistry, or any module setup runs, so a crash during any of
/// that startup work is still caught rather than silently unhandled just
/// because this hadn't been installed yet.
+ (void)installHandler;

/// Appends one breadcrumb to the in-memory ring buffer (most recent 20 kept,
/// oldest dropped first). Internally synchronized -- safe to call from any
/// thread/queue. Cheap enough to call on every bridge dispatch and every
/// module-open decision; this is the whole point of the feature, so callers
/// should err toward adding one rather than skipping it "because it's probably
/// fine here".
+ (void)addBreadcrumb:(NSString *)breadcrumb;

/// If a PREVIOUS launch's uncaught-exception handler persisted a crash
/// report, POSTs it (as-is, opaque JSON body -- see server.py's
/// /api/crash-report route) to the theme server and deletes the on-disk file
/// only once that POST gets back a 2xx. No-ops silently, exactly like
/// GLAppStateReporter.m's +report, when there is no pending report or
/// GL_BAKED_HOST is unbaked (every simulator/CI build) -- never raises, and
/// a failed send leaves the file for the next launch to retry rather than
/// losing the report. Call once per launch, after -installHandler.
+ (void)reportPendingCrashIfAny;

@end

NS_ASSUME_NONNULL_END
