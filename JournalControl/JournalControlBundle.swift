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
            // Custom intent whose perform() RETURNS an OpenURLIntent — using
            // OpenURLIntent directly as the action here silently did nothing
            // on device. See JournalIntent.swift for the full history.
            ControlWidgetButton(action: StartJournalIntent()) {
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
            ControlWidgetButton(action: OpenTextJournalIntent()) {
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
