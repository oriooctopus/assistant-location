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

@main
struct JournalControlBundle: WidgetBundle {
    var body: some Widget {
        JournalControl()
        // Lock Screen accessory widget — a separate WidgetKit surface from
        // the Control above. See JournalLockScreenWidget.swift.
        JournalLockScreenWidget()
    }
}
