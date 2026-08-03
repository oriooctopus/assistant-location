// Centralizes NSUserDefaults keys that are currently written as raw string
// literals in their own files, breaking the GL*DefaultsName convention used
// throughout GLManager.h. Defines the constants only — the call sites below
// are NOT updated in this pass (a concurrent/later change owns those files):
//
//   Modules/Tracker/TrackerAppLifecycle.m:141  -> GLAutoEnableTrackingDefaultsName
//   GPSLogger/SceneDelegate.m:18                -> GLBuildAlertShownStampDefaultsName

#import <Foundation/Foundation.h>

/// Guards the one-time auto-enable-tracking-on-first-launch behavior in
/// TrackerAppLifecycle so the user can turn tracking back off afterwards
/// without it re-enabling itself. Raw value today: "AssistantDidAutoEnableTracking".
static NSString *const GLAutoEnableTrackingDefaultsName = @"AssistantDidAutoEnableTracking";

/// Holds the build stamp the first-launch diagnostic alert was last shown
/// for, so it appears exactly once per installed build. Raw value today:
/// "AssistantBuildAlertShownStamp".
static NSString *const GLBuildAlertShownStampDefaultsName = @"AssistantBuildAlertShownStamp";
