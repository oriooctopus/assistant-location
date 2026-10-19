import UserNotifications

/// Spike 1b: on a visible push carrying `nagId`, cancel the app's pending local
/// backup `nag-<nagId>-local` from inside the extension and report the outcome.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content.mutableCopy() as! UNMutableNotificationContent
        self.handler = contentHandler
        self.content = content
        guard let nagId = content.userInfo["nagId"] as? String else {
            content.body += "\n[nse: no nagId in payload]"
            contentHandler(content)
            return
        }
        let center = UNUserNotificationCenter.current()
        let backupId = "nag-\(nagId)-local"
        center.getPendingNotificationRequests { before in
            let wasPending = before.contains { $0.identifier == backupId }
            center.removePendingNotificationRequests(withIdentifiers: [backupId])
            center.getPendingNotificationRequests { after in
                let stillThere = after.contains { $0.identifier == backupId }
                let cancelled = wasPending && !stillThere
                content.body += "\nbackup cancelled: \(cancelled ? "yes" : "no") (was pending: \(wasPending ? "yes" : "no")), pending left: \(after.count)"
                var req = URLRequest(url: URL(string: "http://wsl-esme-1.tailc6cd5d.ts.net:8329/spike/event")!)
                req.httpMethod = "POST"
                req.timeoutInterval = 10
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                let body: [String: Any] = ["source": "nse", "nagId": nagId, "cancelled": cancelled,
                                           "wasPending": wasPending, "pendingAfter": after.count]
                req.httpBody = try! JSONSerialization.data(withJSONObject: body)
                URLSession.shared.dataTask(with: req) { _, resp, err in
                    if let err = err { content.body += "\n[nse post failed: \(err.localizedDescription)]" }
                    else if let http = resp as? HTTPURLResponse, http.statusCode != 200 { content.body += "\n[nse post status \(http.statusCode)]" }
                    contentHandler(content)
                }.resume()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = content, let handler = handler {
            content.body += "\n[nse: time expired]"
            handler(content)
        }
    }
}
