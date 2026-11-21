import UserNotifications

/// On a nag push: cancel the app's pending local backup alert for the same nag, then sweep every other alert the server says is
/// over (a reminder completed or moved elsewhere whose own dismiss push iOS never delivered), then show the push.
/// The backup's identifier is the push's `nagId` (`<reminderId>:<nagTime>`). Runs even when the app is killed (proven by the
/// DueSpike test).
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private let lock = NSLock()

    /// Calls the content handler exactly once: the sweep finishing and serviceExtensionTimeWillExpire can race.
    private func deliver() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h = h, let c = c { h(c) }
    }

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content.mutableCopy() as! UNMutableNotificationContent
        self.handler = contentHandler
        self.content = content
        if let nagId = content.userInfo["nagId"] as? String {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [nagId])
        }
        // The removal is synchronous with respect to the notification center's queue; reading pending requests back
        // flushes it before the sweep or the handler runs. The sweep fetches /api/state (8 s timeout, well inside the ~30 s the
        // system gives an extension) and the push is delivered whether or not it worked: a failed sweep must never swallow an alert.
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] _ in
            Sweep.run(timeout: 8) { ok, summary in
                NSLog("due-nse: sweep \(ok ? "ok" : "failed"): \(summary)")
                self?.deliver()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() { deliver() }
}
