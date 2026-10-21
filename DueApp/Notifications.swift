import UIKit
import UserNotifications

/// Local backup alerts: one per upcoming nag, firing `grace` after the nag time. If the server's push for the nag arrives,
/// the Notification Service Extension cancels the matching backup (same identifier), so the phone alerts once.
enum Notifications {
    static let category = "DUE_NAG"
    static let grace: TimeInterval = 120
    static let maxPending = 60 // iOS keeps the 64 soonest
    private static let queue = DispatchQueue(label: "due.schedule")

    static func registerCategories() {
        func a(_ id: String, _ title: String) -> UNNotificationAction { UNNotificationAction(identifier: id, title: title, options: []) }
        let cat = UNNotificationCategory(
            identifier: category,
            actions: [a("done", "Done"), a("snooze-10", "Snooze 10 min"), a("snooze-60", "Snooze 1 hour"), a("snooze-tomorrow", "Tomorrow")],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    struct Nag { let id: String; let reminderId: String; let at: Date; let title: String; let timeSensitive: Bool }

    /// Make the pending set equal the given nags (nearest first). Existing alerts for still-wanted nags are kept untouched;
    /// a nag whose time has passed never gets a new alert (only its already-pending one survives).
    static func replace(with raw: [[String: Any]]) {
        let nags: [Nag] = raw.map {
            Nag(id: $0["id"] as! String, reminderId: $0["reminderId"] as! String,
                at: Date(timeIntervalSince1970: ($0["at"] as! Double) / 1000), title: $0["title"] as! String,
                timeSensitive: ($0["level"] as? String) == "timeSensitive")
        }
        let wanted = Array(nags.sorted { $0.at < $1.at }.prefix(maxPending))
        queue.async {
            let center = UNUserNotificationCenter.current()
            let sem = DispatchSemaphore(value: 0)
            var pending: [UNNotificationRequest] = []
            center.getPendingNotificationRequests { pending = $0; sem.signal() }
            sem.wait()
            let wantedIds = Set(wanted.map(\.id))
            let have = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
            let stale = pending.map(\.identifier).filter { !wantedIds.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            let now = Date()
            for n in wanted {
                let fire = n.at.addingTimeInterval(grace)
                if let existing = have[n.id], existing.content.body == n.title { continue }
                if n.at <= now { continue }
                let c = UNMutableNotificationContent()
                c.body = n.title
                c.sound = .default
                c.categoryIdentifier = category
                c.threadIdentifier = n.reminderId
                c.userInfo = ["reminderId": n.reminderId, "nagId": n.id]
                if n.timeSensitive { c.interruptionLevel = .timeSensitive }
                let req = UNNotificationRequest(identifier: n.id, content: c,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSince(now)), repeats: false))
                center.add(req) { if let e = $0 { NSLog("due: schedule \(n.id) failed: \(e)") } }
            }
        }
    }
}
