import UserNotifications

/// On a nag push, cancel the app's pending local backup alert for the same nag. The backup's identifier is the push's `nagId`
/// (`<reminderId>:<nagTime>`). Runs even when the app is killed (proven by the DueSpike test).
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content.mutableCopy() as! UNMutableNotificationContent
        self.handler = contentHandler
        self.content = content
        if let nagId = content.userInfo["nagId"] as? String {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [nagId])
        }
        // The removal is synchronous with respect to the notification center's queue; reading pending requests back
        // flushes it before the extension is allowed to finish.
        UNUserNotificationCenter.current().getPendingNotificationRequests { _ in contentHandler(content) }
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = content, let handler = handler { handler(content) }
    }
}
