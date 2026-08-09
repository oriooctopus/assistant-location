// Lock-screen Control that launches Overland straight into the Journal tab
// and starts recording. StartJournalIntent (JournalIntent.swift, compiled
// into both this extension and the app target) runs in the app's process
// via openAppWhenRun and posts a notification the app side
// (Modules/AutoJournal/AutoJournalViewController.m) observes.

import AppIntents
import SwiftUI
import WidgetKit

struct JournalControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.oliverullman.assistantlocation.journalcontrol"
        ) {
            ControlWidgetButton(action: StartJournalIntent()) {
                Label("Voice Journal", systemImage: "mic.fill")
            }
        }
        .displayName("Voice Journal")
    }
}

// Text-entry counterpart to JournalControl above, same native Control
// surface (glass background, full opacity — unlike the accessory widget in
// JournalLockScreenWidget.swift, which Apple forces into pale vibrant/mono
// rendering with no custom background). Add this to the OTHER corner slot
// via Settings > Customize Lock Screen > Controls for a matching crisp look.
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
        // Lock Screen accessory widget — a separate WidgetKit surface from
        // the Controls above. See JournalLockScreenWidget.swift.
        JournalLockScreenWidget()
    }
}
