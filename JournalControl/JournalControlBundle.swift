// Lock-screen / Control Center Controls that launch Assistant Location into
// the Journal tab. See JournalIntent.swift for why these open a URL rather
// than posting a notification from an AppIntent's perform().

import AppIntents
import SwiftUI
import WidgetKit

struct JournalControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.oliverullman.assistantlocation.journalcontrol"
        ) {
            // OpenURLIntent is a system intent: iOS opens the URL in the
            // owning app itself, so the handling code runs in the app's
            // process (unlike a custom AppIntent's perform(), which runs in
            // this extension — the bug this replaced).
            ControlWidgetButton(action: OpenURLIntent(JournalDeepLink.voice)) {
                Label("Voice Journal", systemImage: "mic.fill")
            }
        }
        .displayName("Voice Journal")
    }
}

struct JournalTextControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.oliverullman.assistantlocation.journaltextcontrol"
        ) {
            ControlWidgetButton(action: OpenURLIntent(JournalDeepLink.text)) {
                Label("Text Journal", systemImage: "square.and.pencil")
            }
        }
        .displayName("Text Journal")
    }
}

@main
struct JournalControlBundle: WidgetBundle {
    var body: some Widget {
        JournalControl()
        JournalTextControl()
        // Lock Screen accessory widgets (accessoryCircular) — a separate
        // WidgetKit surface from the Controls above. See
        // JournalLockScreenWidget.swift.
        JournalVoiceLockScreenWidget()
        JournalTextLockScreenWidget()
    }
}
