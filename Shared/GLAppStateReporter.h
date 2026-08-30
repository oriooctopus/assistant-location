// Reports what is ACTUALLY running on the device — build stamp, bundle
// version, baked commit, resolved theme, hardware/OS — to the theme server.
// Nothing about a running install reaches the server today: the on-screen
// build-diagnostic alert (SceneDelegate.m's -presentBuildDiagnosticIfNeeded:)
// shows build stamp / bundle version, but only to whoever is physically
// looking at the phone. That blind spot is not hypothetical: a theming bug
// was verified against `dusk-dark` for days server-side while the phone was
// actually rendering `dusk-light`, because nothing told the server which
// variant the device had resolved.
//
// Fire-and-forget, diagnostics only. No completion handler, no retry, no
// user-visible effect, and no error surfaced anywhere — see
// GLAppStateReporter.m's +report for exactly how it stays inert on a
// simulator/CI build instead of crashing or spamming an unreachable host.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLAppStateReporter : NSObject

/// POSTs the current app/device/theme state as JSON to /api/app-state on the
/// theme server (same host as everything else in the app, port 8304 — see
/// GLTheme.m's palette fetch). No-ops silently when GL_BAKED_HOST is
/// unbaked, which is every simulator/CI build; never raises.
///
/// Call once per launch (App/SceneDelegate.m, alongside the existing build
/// diagnostic) — this class also calls itself on GLThemeDidChangeNotification
/// and after GLTheme.m's own palette-refresh commits, so a theme change made
/// from Settings, or a resolved-variant change from the OS flipping
/// light/dark under System mode, reaches the server without waiting for the
/// next cold launch.
+ (void)report;

@end

NS_ASSUME_NONNULL_END
