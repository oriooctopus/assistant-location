// Intents behind the "New session (voice)"/"New session (text)" lock-screen
// Controls -- same OpenURLIntent + notification-post + openURL triple-fire
// shape as JournalIntent.swift, and for the same reason: read that file's
// header comment in full before touching this one. Short version: perform()
// posts an NSNotification (wins when the OS runs perform() in the app's own
// process, warm or background-pre-launched) AND opens overland://session/...
// (covers cold-launch delivery via SceneDelegate -> GLModuleRegistry
// routeURL: -> SessionsModule +moduleHandleURL:, since custom-scheme URLs
// don't reach a Control's perform() via .result(opensIntent:) at all).
//
// Deliberately NOT reusing JournalVoiceControlIntent/JournalTextControlIntent
// -- a Control's intent type identity is part of its persisted registration
// (see JournalIntent.swift's "fresh names" note), and Sessions is a
// genuinely different destination (overland://session/... vs
// overland://journal/...), so it gets its own intent types from the start
// rather than overloading Journal's.

import AppIntents
import Foundation
import SwiftUI

@available(iOS 18.0, *)
enum SessionDeepLink {
    static let voice = URL(string: "overland://session/voice")!
    static let text = URL(string: "overland://session/text")!
}

@available(iOS 18.0, *)
struct SessionVoiceControlIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session (Voice)"
    static let description = IntentDescription("Open Assistant Location and start a new Claude Code session from a voice prompt.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("perform() ran (session voice)")
        NotificationCenter.default.post(name: Notification.Name("GLSessionsStartVoice"), object: nil)
        EnvironmentValues().openURL(SessionDeepLink.voice)
        return .result()
    }
}

@available(iOS 18.0, *)
struct SessionTextControlIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session (Text)"
    static let description = IntentDescription("Open Assistant Location and start a new Claude Code session from a typed prompt.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("perform() ran (session text)")
        NotificationCenter.default.post(name: Notification.Name("GLSessionsStartText"), object: nil)
        EnvironmentValues().openURL(SessionDeepLink.text)
        return .result()
    }
}
