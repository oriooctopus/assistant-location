// Lock-screen / Control Center Controls that launch Assistant Location into
// the Journal tab. See JournalIntent.swift for why these open a URL rather
// than posting a notification from an AppIntent's perform().

import AppIntents
import SwiftUI
import WidgetKit

struct JournalControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.oliverullman.assistantlocation.journalcontrol2"
        ) {
            // The "2" kind suffix and the fresh intent type names force iOS
            // to register these Controls from scratch — stale registrations
            // were silently skipping perform() entirely. See
            // JournalIntent.swift's header for the full four-design history.
            // Old Controls on the lock screen die with the rename; they must
            // be removed and re-added once.
            ControlWidgetButton(action: JournalVoiceControlIntent()) {
                Label("Voice Journal", systemImage: "mic.fill")
            }
        }
        .displayName("Voice Journal")
    }
}

struct JournalTextControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.oliverullman.assistantlocation.journaltextcontrol2"
        ) {
            ControlWidgetButton(action: JournalTextControlIntent()) {
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
