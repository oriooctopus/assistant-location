import Foundation
import UserNotifications

/// Prunes local alerts the server says are over. Compiled into the app, DueNSE (every alert push runs it) and DueTests, so the
/// app and the extension apply one rule. Only Foundation + UserNotifications + Keychain/Baked, nothing app-only (no Registration,
/// no UIKit), because the extension target has none of that.
///
/// Why this exists: backups are local notifications scheduled ahead of time, and iOS gives no guarantee that the silent dismiss
/// push (or any app wake) arrives. A reminder completed on another device kept firing backups for hours. Every other alert push
/// reaching the NSE, the app coming forward and a background refresh are extra chances to prune.
enum Sweep {
    /// What the server currently says: `live` maps open reminders to their dueAt, `closed` holds completed or deleted ones.
    struct ServerState: Equatable {
        var live: [String: Double]
        var closed: Set<String>
    }

    /// The /api/state body -> ServerState. nil when the body is not the expected shape (the caller reports it, never guesses).
    static func parse(_ data: Data) -> ServerState? {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reminders = state["reminders"] as? [String: [String: Any]] else { return nil }
        var live: [String: Double] = [:], closed = Set<String>()
        for (id, r) in reminders {
            if r["completedAt"] is NSNull, r["deletedAt"] is NSNull, let dueAt = (r["dueAt"] as? NSNumber)?.doubleValue { live[id] = dueAt } else { closed.insert(id) }
        }
        return ServerState(live: live, closed: closed)
    }

    /// A delivered alert is stale when its reminder is gone from `live` or sits at another dueAt (repeat advanced, snoozed).
    /// Alerts delivered before pushes carried dueAt have none: they never match, so they count as stale.
    static func isStaleDelivered(_ info: [AnyHashable: Any], live: [String: Double]) -> Bool {
        guard let id = info["reminderId"] as? String else { return false }
        return live[id] != (info["dueAt"] as? NSNumber)?.doubleValue
    }

    /// A pending backup is pruned when its reminder is closed, or the server's dueAt has moved PAST the backup's (snoozed or
    /// rescheduled elsewhere, so the backup would fire for a time that no longer applies).
    /// Kept: a backup dueAt GREATER than the server's (a local offline snooze the server has not seen yet), one for a reminder the
    /// server does not know (created offline), and one without a dueAt (cannot be compared).
    static func shouldPruneBackup(_ info: [AnyHashable: Any], state: ServerState) -> Bool {
        guard let id = info["reminderId"] as? String else { return false }
        if state.closed.contains(id) { return true }
        guard let serverDueAt = state.live[id], let backupDueAt = (info["dueAt"] as? NSNumber)?.doubleValue else { return false }
        return backupDueAt < serverDueAt
    }

    /// GET /api/state with the shared-keychain token. `done` gets nil state plus the reason when unavailable (no token, HTTP error,
    /// unexpected body); the reason is for logs only.
    static func fetchState(timeout: TimeInterval, done: @escaping (ServerState?, String) -> Void) {
        guard let token = Keychain.token else { return done(nil, "keychain token unavailable") }
        var req = URLRequest(url: URL(string: Baked.server + "/api/state")!)
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, let data = data else { return done(nil, "HTTP \(status) \(String(describing: err))") }
            guard let state = parse(data) else { return done(nil, "unexpected /api/state shape") }
            done(state, "ok")
        }.resume()
    }

    /// Removes the delivered alerts and pending backups `state` says are over; `done` gets the removed counts.
    /// Blocks its calling thread on the notification center, so call it off the main thread.
    static func prune(_ state: ServerState, done: (_ delivered: Int, _ pending: Int) -> Void) {
        let center = UNUserNotificationCenter.current()
        let sem = DispatchSemaphore(value: 0)
        var delivered: [UNNotification] = [], pending: [UNNotificationRequest] = []
        center.getDeliveredNotifications { delivered = $0; sem.signal() }
        center.getPendingNotificationRequests { pending = $0; sem.signal() }
        sem.wait(); sem.wait()
        let staleDelivered = delivered.filter { isStaleDelivered($0.request.content.userInfo, live: state.live) }.map(\.request.identifier)
        let stalePending = pending.filter { shouldPruneBackup($0.content.userInfo, state: state) }.map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: staleDelivered)
        center.removePendingNotificationRequests(withIdentifiers: stalePending)
        done(staleDelivered.count, stalePending.count)
    }

    private static let queue = DispatchQueue(label: "due.sweep")

    /// Fetch then prune. `done` gets a one-line outcome for the log and is always called, failure included.
    static func run(timeout: TimeInterval, done: @escaping (_ ok: Bool, _ summary: String) -> Void) {
        fetchState(timeout: timeout) { state, why in
            guard let state = state else { return done(false, why) }
            queue.async { prune(state) { d, p in done(true, "removed \(d) delivered, \(p) pending") } }
        }
    }
}
