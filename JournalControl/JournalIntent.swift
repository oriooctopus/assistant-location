// Intents behind the lock-screen Controls and accessory widgets.
//
// HISTORY OF A HARD BUG — read before "simplifying" any of this. The Controls
// went through four failed designs, all with the same symptom (app opens on
// the default tab, nothing records), each disproven by server-side logging:
//
// 1. perform() posting NSNotification, assuming perform runs in the app
//    process. Zero handler logs. NOTE: later research showed the diagnosis
//    ("perform runs in the extension") was itself shaky — for intents
//    compiled into BOTH targets with openAppWhenRun=true, iOS pre-launches
//    the app into the background and runs perform() in the APP process
//    (zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process;
//    Apple's openAppWhenRun doc). The likely real failure: every on-device
//    test followed a reinstall, so the app always cold-launched, and the
//    notification fired before the Journal tab's observer existed.
// 2. ControlWidgetButton(action: OpenURLIntent(url)) directly — app opens,
//    URL never delivered (cold launches log URLContexts count=0).
// 3. perform() returning .result(opensIntent: OpenURLIntent(url)) — same.
//    Apple only routes UNIVERSAL LINKS through the opensIntent path (forum
//    threads 762586/758911, DTS engineer confirmation); custom schemes are
//    silently dropped. A universal link needs a public associated domain —
//    impossible for this app's tailnet-only server.
// 4. perform() calling EnvironmentValues().openURL(url) — and an awaited
//    server-log call as perform()'s FIRST LINE never fired, from either
//    process, across multiple presses. So perform() wasn't running at all:
//    matches the known iOS 18 silent-skip class where a Control's stale
//    registration stops invoking the intent (forum thread 789371 is the
//    same family). Documented workaround: fresh intent type names + user
//    removes and re-adds the Controls.
//
// Hence the current shape: RENAMED intent structs (fresh registration —
// renaming is load-bearing, do not rename back to the old names), and
// perform() does all three of: server debug log (proves it ran), direct
// NSNotification post (wins when perform runs in the app process — warm or
// background-pre-launched), and openURL (covers cold-launch delivery via
// the scene delegate, which routes it through GLModuleRegistry routeURL: ->
// AutoJournalModule +moduleHandleURL:). The handler tolerates the double
// trigger in the warm case: a second GLJournalStartCapture while already
// recording is skipped as not-idle.
//
// No App Group entitlement anywhere in this design (deliberately dropped —
// the App Store Connect API can't manage that capability's settings key).
// The `overland` scheme is registered in App/Info.plist (CFBundleURLTypes).

import AppIntents
import Foundation
import SwiftUI

// All three are iOS 18-only because OpenURLIntent is. The annotation matters:
// this file is compiled into BOTH the JournalControl extension (deployment
// target 18.0) and the app target (15.0) — without it the app-side compile
// fails. Compiling into both targets is itself load-bearing: it's what lets
// iOS run perform() in the app's process.
@available(iOS 18.0, *)
enum JournalDeepLink {
    static let voice = URL(string: "overland://journal/voice")!
    static let text = URL(string: "overland://journal/text")!
}

// Fresh names (previously StartJournalIntent / OpenTextJournalIntent) to
// force iOS to re-register the Controls' intents — see design #4 above.
@available(iOS 18.0, *)
struct JournalVoiceControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Voice Journal"
    static let description = IntentDescription("Open Assistant Location and start recording a voice journal entry.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("perform() ran (voice)")
        NotificationCenter.default.post(name: Notification.Name("GLJournalStartCapture"), object: nil)
        EnvironmentValues().openURL(JournalDeepLink.voice)
        return .result()
    }
}

@available(iOS 18.0, *)
struct JournalTextControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Text Journal"
    static let description = IntentDescription("Open Assistant Location to the journal tab for a text entry.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("perform() ran (text)")
        NotificationCenter.default.post(name: Notification.Name("GLJournalStartTextEntry"), object: nil)
        EnvironmentValues().openURL(JournalDeepLink.text)
        return .result()
    }
}

// EXPERIMENT V2 — identical to the intents above except for conforming to
// AudioPlaybackIntent, whose one documented superpower is FORCING perform()
// to run in the APP's process (the only marker protocols that do:
// AudioPlaybackIntent / LiveActivityIntent / ForegroundContinuableIntent —
// see zachwaugh.com/posts/forcing-appintent-to-run-in-main-app-process).
// If the V2 Controls work where V1 doesn't, process placement was the whole
// story. Semantically "playback" is a stretch (we record), but the protocol
// is just a scheduling hint; nothing audio-related is required of us.
@available(iOS 18.0, *)
struct JournalVoiceV2Intent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Voice Journal V2"
    static let description = IntentDescription("Voice journal via app-process intent (experiment V2).")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("V2 perform() ran (voice)")
        NotificationCenter.default.post(name: Notification.Name("GLJournalStartCapture"), object: nil)
        EnvironmentValues().openURL(JournalDeepLink.voice)
        return .result()
    }
}

@available(iOS 18.0, *)
struct JournalTextV2Intent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Text Journal V2"
    static let description = IntentDescription("Text journal via app-process intent (experiment V2).")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await journalDebugLog("V2 perform() ran (text)")
        NotificationCenter.default.post(name: Notification.Name("GLJournalStartTextEntry"), object: nil)
        EnvironmentValues().openURL(JournalDeepLink.text)
        return .result()
    }
}
