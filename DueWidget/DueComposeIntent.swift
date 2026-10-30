// Intent behind the lock-screen "New Reminder" Control. Same shape as JournalControl/JournalIntent.swift (read its header
// for the bug history): perform() posts the notification (wins when iOS runs perform in the app process) AND opens the
// URL (covers cold launch). Compiled into BOTH the Due app and the DueWidget extension; that is what lets iOS run
// perform() in the app's process. No App Group, so there is no shared state to write.

import AppIntents
import Foundation
import SwiftUI

extension Notification.Name {
    static let dueCompose = Notification.Name("DueCompose")
}

// iOS 18-only because OpenURLIntent is; the app target deploys at 16.
@available(iOS 18.0, *)
enum DueDeepLink {
    static let compose = URL(string: "dueclone://new")!
}

@available(iOS 18.0, *)
struct DueNewReminderControlIntent: AppIntent {
    static let title: LocalizedStringResource = "New Reminder"
    static let description = IntentDescription("Open Due to the New Reminder sheet.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .dueCompose, object: nil)
        EnvironmentValues().openURL(DueDeepLink.compose)
        return .result()
    }
}
