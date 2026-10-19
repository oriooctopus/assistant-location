import SwiftUI
import UserNotifications

let spikeBase = "http://wsl-esme-1.tailc6cd5d.ts.net:8329"

@main
struct DueSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Model.shared.log("device token \(token.prefix(8))...")
        Model.shared.post("/spike/register", ["token": token])
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Model.shared.log("register FAILED: \(error.localizedDescription)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let c = notification.request.content
        Model.shared.log("willPresent \(notification.request.identifier): \(c.body.replacingOccurrences(of: "\n", with: " | "))")
        Model.shared.post("/spike/event", ["source": "app", "event": "willPresent", "id": notification.request.identifier])
        completionHandler([.banner, .sound, .list])
    }
}

final class Model: ObservableObject {
    static let shared = Model()
    @Published var lines: [String] = []
    @Published var pending: [String] = []
    @Published var serverEvents: [String] = []
    @Published var settings = ""

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        DispatchQueue.main.async { self.lines.insert("\(f.string(from: Date())) \(s)", at: 0) }
    }

    func post(_ path: String, _ body: [String: Any]) {
        var req = URLRequest(url: URL(string: spikeBase + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err = err { self.log("POST \(path) failed: \(err.localizedDescription)") }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 { self.log("POST \(path) status \(http.statusCode)") }
        }.resume()
    }

    func refresh() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let rows = reqs.map { r -> String in
                let at = (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate().map { f.string(from: $0) } ?? "?"
                return "\(r.identifier) @ \(at)"
            }
            DispatchQueue.main.async { self.pending = rows }
        }
        center.getNotificationSettings { s in
            let txt = "alert=\(s.alertSetting.rawValue) sound=\(s.soundSetting.rawValue) timeSensitive=\(s.timeSensitiveSetting.rawValue) (2=enabled)"
            DispatchQueue.main.async { self.settings = txt }
        }
        var req = URLRequest(url: URL(string: spikeBase + "/spike/events")!)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                if let err = err { self.log("GET events failed: \(err.localizedDescription)") }
                return
            }
            let rows = arr.suffix(30).reversed().map { e -> String in
                let ts = String((e["ts"] as? String ?? "").dropFirst(11).prefix(8))
                let rest = e.filter { $0.key != "ts" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                return "\(ts) \(rest)"
            }
            DispatchQueue.main.async { self.serverEvents = Array(rows) }
        }.resume()
    }

    func schedule(id: String, title: String, after: TimeInterval) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = "Local time-sensitive notification"
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: id, content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: after, repeats: false))
        UNUserNotificationCenter.current().add(req) { err in
            self.log(err.map { "schedule \(id) FAILED: \($0.localizedDescription)" } ?? "scheduled \(id) in \(Int(after))s")
            self.refresh()
        }
    }

    func startDedupTest() {
        let nagId = String(UUID().uuidString.prefix(6)).lowercased()
        schedule(id: "nag-\(nagId)-local", title: "Nag \(nagId) (LOCAL backup)", after: 180)
        let fireAt = Int((Date().timeIntervalSince1970 + 60) * 1000)
        post("/spike/schedule", ["nagId": nagId, "fireAt": fireAt])
        log("dedup test \(nagId): local backup at +3min, server push at +1min")
    }
}

struct ContentView: View {
    @ObservedObject var model = Model.shared
    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section("Actions") {
                Button("Start dedup test") { model.startDedupTest() }
                Button("Local time-sensitive in 30s") {
                    model.schedule(id: "ts-\(Int(Date().timeIntervalSince1970))", title: "Time-sensitive local", after: 30)
                }
                Button("Refresh") { model.refresh() }
            }
            Section("Settings") { Text(model.settings).font(.caption.monospaced()) }
            Section("Pending local (\(model.pending.count))") {
                ForEach(model.pending, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
            Section("Server events (incl. NSE)") {
                ForEach(Array(model.serverEvents.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
            }
            Section("App log") {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
            }
        }
        .onReceive(timer) { _ in model.refresh() }
        .onAppear {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
                model.log("authorization granted=\(granted) err=\(err?.localizedDescription ?? "none")")
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
            model.refresh()
        }
    }
}
