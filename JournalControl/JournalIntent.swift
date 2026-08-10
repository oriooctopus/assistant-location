// Intents behind the lock-screen Controls and accessory widgets.
//
// IMPORTANT — why these open a URL instead of posting a notification:
//
// The previous version set openAppWhenRun = true and posted an
// NSNotification from perform(), on the assumption that perform() runs
// inside the APP's process (making a plain in-process notification enough,
// with no App Group entitlement needed). That assumption is wrong.
// perform() runs in the WIDGET EXTENSION's process; openAppWhenRun only
// launches/foregrounds the app. So the notification was delivered inside
// the extension, where nothing observes it, and the app just came to the
// foreground on whatever tab it was already showing — the exact reported
// symptom.
//
// This was proven, not guessed: the notification handler in
// Modules/AutoJournal/AutoJournalViewController.m was instrumented to log
// to the location server on entry, the built IPA was verified to actually
// contain that code, the phone was confirmed to have downloaded that exact
// build, and pressing the Controls produced zero log lines.
//
// A URL crosses the process boundary correctly and needs no App Group
// (which was deliberately dropped — the App Store Connect API can't manage
// that capability's settings key). iOS hands the URL to the app's
// SceneDelegate -scene:openURLContexts:, which already routes through
// GLModuleRegistry routeURL: to AutoJournalModule +moduleHandleURL:, where
// the notification is posted in the process that actually observes it.
//
// The `overland` scheme is registered in App/Info.plist (CFBundleURLTypes).

import AppIntents
import Foundation

@available(iOS 16.0, *)
enum JournalDeepLink {
    static let voice = URL(string: "overland://journal/voice")!
    static let text = URL(string: "overland://journal/text")!
}
