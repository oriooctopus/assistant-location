// Lock-screen Control that launches Overland straight into the Journal tab
// and starts recording. The Control itself only flips a flag in the shared
// App Group's UserDefaults and opens the app (openAppWhenRun); the app side
// (Modules/AutoJournal/AutoJournalViewController.m) notices the flag on
// UIApplicationDidBecomeActiveNotification and does the actual tab-select +
// record-start.

import AppIntents
import SwiftUI
import WidgetKit

private let appGroupSuite = "group.com.oliverullman.assistantlocation"
private let pendingCaptureKey = "GLJournalPendingCapture"

struct StartJournalIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Journal Entry"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: appGroupSuite)
        defaults?.set(true, forKey: pendingCaptureKey)
        return .result()
    }
}

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
    }
}
