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
// Why perform() CALLS EnvironmentValues().openURL instead of the button
// using OpenURLIntent directly or perform() returning
// .result(opensIntent: OpenURLIntent(...)): both of those forms silently
// drop CUSTOM URL schemes on device — the app foregrounds but the URL is
// never delivered to the scene (verified by server-side logging: cold
// launches arrived with URLContexts count=0). Apple only routes UNIVERSAL
// LINKS through the opensIntent path (forum threads 762586/758911, DTS
// engineer confirmation), and a universal link requires a public
// associated domain, which this app's tailnet-only server cannot be.
// Calling openURL directly inside perform() is the community-verified
// fallback that delivers a custom scheme.
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
import SwiftUI

// All three are iOS 18-only because OpenURLIntent is. The annotation matters:
// this file is compiled into BOTH the JournalControl extension (deployment
// target 18.0) and the app target (15.0) — without it the app-side compile
// fails.
@available(iOS 18.0, *)
enum JournalDeepLink {
    static let voice = URL(string: "overland://journal/voice")!
    static let text = URL(string: "overland://journal/text")!
}

@available(iOS 18.0, *)
struct StartJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Voice Journal"
    static let description = IntentDescription("Open Assistant Location and start recording a voice journal entry.")
    // Foregrounds the app; the returned OpenURLIntent then delivers the deep
    // link into the app's scene. Both halves are load-bearing.
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("extension perform() ran (voice) — calling openURL")
        // NOT returned as .result(opensIntent:): iOS silently drops CUSTOM
        // URL schemes returned from a Control's intent — only universal
        // links are routed that way (Apple forum threads 762586/758911;
        // confirmed by an Apple DTS engineer). A universal link needs a
        // public associated domain, which this tailnet-only server can't
        // be, so the community-verified fallback is calling openURL
        // directly inside perform().
        EnvironmentValues().openURL(JournalDeepLink.voice)
        return .result()
    }
}

@available(iOS 18.0, *)
struct OpenTextJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Text Journal"
    static let description = IntentDescription("Open Assistant Location to the journal tab for a text entry.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("extension perform() ran (text) — calling openURL")
        EnvironmentValues().openURL(JournalDeepLink.text)
        return .result()
    }
}
