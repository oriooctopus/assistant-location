// StartJournalIntent lives in its own file, deliberately compiled into BOTH
// the JournalControl extension target AND the Overland app target (see
// scripts/add_journal_control_ext.rb). Swift type identity for AppIntents is
// by name, not by module, so having the same source in two targets gives the
// extension and the app the same intent type.
//
// Why this works without an App Group: openAppWhenRun = true tells the
// system to launch/foreground the app and run -perform() INSIDE THE APP'S
// OWN PROCESS, not the extension's. Because it runs in-process, it doesn't
// need cross-process storage (no shared UserDefaults suite, no App Group
// entitlement) — it just posts a normal NSNotification that
// Modules/AutoJournal/AutoJournalViewController.m observes in that same
// process.
//
// App Groups were dropped entirely: the App Store Connect API rejects that
// capability's settings key (only manageable via the legacy Developer Portal
// API, which needs Apple ID cookie auth CI doesn't have).

import AppIntents
import Foundation

struct StartJournalIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Journal Entry"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("GLJournalStartCapture"), object: nil)
        return .result()
    }
}
