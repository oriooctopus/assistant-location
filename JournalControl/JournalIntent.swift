// Intents behind the lock-screen Controls and accessory widgets.
//
// IMPORTANT — why these open a URL instead of posting a notification:
//
// An earlier version set openAppWhenRun = true and posted an NSNotification
// from perform(), on the assumption that perform() runs inside the APP's
// process. That assumption is wrong: perform() runs in the WIDGET
// EXTENSION's process, so the notification was delivered where nothing
// observes it and the app just foregrounded on whatever tab it was on.
// Proven by server-side logging against a binary verified to contain the
// instrumented handler: zero log lines across many Control presses.
//
// Why perform() RETURNS an OpenURLIntent instead of the Control's button
// using OpenURLIntent directly: ControlWidgetButton(action:
// OpenURLIntent(...)) silently did nothing in on-device testing (same
// zero-log-lines evidence, against a build verified to contain the URL
// string in the .appex binary). Returning .result(opensIntent:) from a
// custom intent's perform() is the documented, reliable pattern — the
// system executes the returned OpenURLIntent in the app-opening context.
//
// The URL crosses the process boundary with no App Group entitlement
// (deliberately dropped — the App Store Connect API can't manage that
// capability's settings key). Delivery on the app side:
//   - warm app: SceneDelegate -scene:openURLContexts:
//   - cold launch: connectionOptions.URLContexts in
//     -scene:willConnectToSession:options: (openURLContexts is NOT called
//     on cold launch — this was a second, independent hole that also
//     produced the "opens on the default tab" symptom)
// Both route through GLModuleRegistry routeURL: to AutoJournalModule
// +moduleHandleURL:, which posts the notification in the app's process.
//
// The `overland` scheme is registered in App/Info.plist (CFBundleURLTypes).

import AppIntents
import Foundation

@available(iOS 16.4, *)
enum JournalDeepLink {
    static let voice = URL(string: "overland://journal/voice")!
    static let text = URL(string: "overland://journal/text")!
}

@available(iOS 16.4, *)
struct StartJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Voice Journal"
    static let description = IntentDescription("Open Assistant Location and start recording a voice journal entry.")
    // Foregrounds the app; the returned OpenURLIntent then delivers the deep
    // link into the app's scene. Both halves are load-bearing.
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        return .result(opensIntent: OpenURLIntent(JournalDeepLink.voice))
    }
}

@available(iOS 16.4, *)
struct OpenTextJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Text Journal"
    static let description = IntentDescription("Open Assistant Location to the journal tab for a text entry.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        return .result(opensIntent: OpenURLIntent(JournalDeepLink.text))
    }
}
