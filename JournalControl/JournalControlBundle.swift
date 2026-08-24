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

// EXPERIMENT V2 Controls — same UI, but the intent conforms to
// AudioPlaybackIntent, which forces perform() into the APP process. Shown
// in the gallery as "Voice/Text Journal V2". If V2 works and V1 doesn't,
// the fix is the protocol conformance; V1 then gets deleted.
struct JournalControlV2: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.oliverullman.assistantlocation.journalcontrol.v2audio"
        ) {
            ControlWidgetButton(action: JournalVoiceV2Intent()) {
                Label("Voice Journal V2", systemImage: "mic.badge.plus")
            }
        }
        .displayName("Voice Journal V2")
    }
}

struct JournalTextControlV2: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.oliverullman.assistantlocation.journaltextcontrol.v2audio"
        ) {
            ControlWidgetButton(action: JournalTextV2Intent()) {
                Label("Text Journal V2", systemImage: "square.and.pencil.circle")
            }
        }
        .displayName("Text Journal V2")
    }
}

@main
struct JournalControlBundle: WidgetBundle {
    var body: some Widget {
        JournalControl()
        JournalTextControl()
        JournalControlV2()
        JournalTextControlV2()
        // Lock Screen accessory widgets (accessoryCircular) — a separate
        // WidgetKit surface from the Controls above. See
        // JournalLockScreenWidget.swift.
        JournalVoiceLockScreenWidget()
        JournalTextLockScreenWidget()
    }
}
