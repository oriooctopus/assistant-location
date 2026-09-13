// Centralizes NSUserDefaults keys that used to be written as raw string
// literals in their own files, breaking the GL*DefaultsName convention used
// throughout GLManager.h:
//
//   Modules/Tracker/TrackerAppLifecycle.m  -> GLAutoEnableTrackingDefaultsName
//   App/SceneDelegate.m                      -> GLBuildAlertShownStampDefaultsName

#import <Foundation/Foundation.h>

/// Guards the one-time auto-enable-tracking-on-first-launch behavior in
/// TrackerAppLifecycle so the user can turn tracking back off afterwards
/// without it re-enabling itself. Raw value today: "AssistantDidAutoEnableTracking".
static NSString *const GLAutoEnableTrackingDefaultsName = @"AssistantDidAutoEnableTracking";

/// Holds the build stamp the first-launch diagnostic alert was last shown
/// for, so it appears exactly once per installed build. Raw value today:
/// "AssistantBuildAlertShownStamp".
static NSString *const GLBuildAlertShownStampDefaultsName = @"AssistantBuildAlertShownStamp";

/// The user's saved tile order on the More grid (see
/// Modules/More/GLMoreGridViewController.m), stored as an array of module
/// restoration identifiers rather than indices so adding, removing or
/// reordering modules can never scramble it. Raw value today:
/// "AssistantMoreGridOrder".
static NSString *const GLMoreGridOrderDefaultsName = @"AssistantMoreGridOrder";

/// Which More-grid tiles the user has promoted to full width ("hero"),
/// stored as an array of the same restoration identifiers. Raw value today:
/// "AssistantMoreGridHeroes".
static NSString *const GLMoreGridHeroesDefaultsName = @"AssistantMoreGridHeroes";

/// Test-only override for a MANAGED page's `GL_BOOT.apiBase` (see
/// GLWebModuleViewController.m's -bootScriptSource), persisted rather than
/// read from the environment on every page load -- sim-test.yml's
/// `xcrun simctl openurl` (used to exercise Sessions' deep links) launches
/// the app WITHOUT the `SIMCTL_CHILD_` env prefix `simctl launch` supports,
/// so a cold launch triggered by openurl needs this to already be persisted
/// from an earlier `simctl launch` in the same test run -- exactly
/// TrackerAppLifecycle.m's UITEST_ENDPOINT -> GLAPIEndpointDefaultsName
/// pattern. Raw value: "AssistantUITestWebPageAPIBase". Production code
/// never writes this key.
static NSString *const GLUITestWebPageAPIBaseDefaultsName = @"AssistantUITestWebPageAPIBase";
