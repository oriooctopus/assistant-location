import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
    private var live: WebViewController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Notifications.registerCategories()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            NSLog("due: notification authorization granted=\(granted) err=\(String(describing: err))")
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        // Launched in the background by a notification action: no UI (a second web context next to the headless one
        // would race on the same storage). The UI is built when the app becomes active.
        if application.applicationState != .background { buildUI() }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if live == nil && !HeadlessRunner.active { buildUI() }
    }

    private func buildUI() {
        let w = UIWindow(frame: UIScreen.main.bounds)
        let vc = WebViewController()
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        live = vc
    }

    // MARK: push token

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        var req = URLRequest(url: URL(string: Baked.server + "/api/devices")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(Baked.token)", forHTTPHeaderField: "authorization")
        req.httpBody = try! JSONSerialization.data(withJSONObject: ["token": token, "platform": "ios"])
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err = err { NSLog("due: device registration failed: \(err.localizedDescription)") }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 { NSLog("due: device registration status \(http.statusCode)") }
            else { NSLog("due: device token registered (\(token.prefix(8))...)") }
        }.resume()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("due: remote notification registration failed: \(error.localizedDescription)")
    }

    // MARK: notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Done / snooze taps. The intent is written to disk first; then it is applied through the live page if there is one,
    /// else through an invisible headless run, so the op reaches the queue (and the server) with the UI closed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let reminderId = response.notification.request.content.userInfo["reminderId"] as? String,
              Intents.append(action: response.actionIdentifier, reminderId: reminderId) else { return completionHandler() }
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        let finish = {
            completionHandler()
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        DispatchQueue.main.async {
            let headless = { HeadlessRunner().run(done: finish) }
            if let vc = self.live { vc.drainIntents { ok in ok ? finish() : headless() } } else { headless() }
        }
    }
}
