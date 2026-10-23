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
            Registration.report("authorization", "granted=\(granted) err=\(String(describing: err))")
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        // Also register at launch regardless of the prompt: the token callback is what we need, and it is cheap.
        application.registerForRemoteNotifications()
        Registration.watchLaunch(application: application)
        // Launched in the background by a notification action: no UI (a second web context next to the headless one
        // would race on the same storage). The UI is built when the app becomes active.
        if application.applicationState != .background { buildUI() }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Registration.retryIfNeeded()
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
        Registration.didRegister(token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let e = error as NSError
        Registration.report("didFailToRegister", "\(e.domain) \(e.code): \(e.localizedDescription)")
    }

    /// Silent push from the server: the reminder was completed, deleted or moved to another dueAt elsewhere, so clear that occurrence's alerts here.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let id = userInfo["dismissReminderId"] as? String, let dueAt = (userInfo["dismissDueAt"] as? NSNumber)?.doubleValue else { return completionHandler(.noData) }
        Notifications.dismiss(reminderId: id, dueAt: dueAt) { completionHandler(.newData) }
    }

    // MARK: notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Done / snooze taps. Applied straight on the server first, then every alert of that occurrence is cleared (iOS only removes
    /// the one tapped). If the server is unreachable the intent is written to disk and applied through the live page if there is
    /// one, else through an invisible headless run, so the op still reaches the queue offline.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let reminderId = info["reminderId"] as? String, Notifications.actionIds.contains(action) else { return completionHandler() }
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        let finish = {
            completionHandler()
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        ServerAction.apply(action: action, reminderId: reminderId) { err in
            if err == nil {
                Registration.report("actionDirect", "\(action) \(reminderId)")
                guard let dueAt = (info["dueAt"] as? NSNumber)?.doubleValue else { return DispatchQueue.main.async(execute: finish) }
                return Notifications.dismiss(reminderId: reminderId, dueAt: dueAt) { DispatchQueue.main.async(execute: finish) }
            }
            Registration.report("actionQueued", "\(action) \(reminderId): \(err!)")
            _ = Intents.append(action: action, reminderId: reminderId)
            DispatchQueue.main.async {
                let headless = { HeadlessRunner().run(done: finish) }
                if let vc = self.live { vc.drainIntents { ok in ok ? finish() : headless() } } else { headless() }
            }
        }
    }
}
