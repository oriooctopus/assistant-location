import UIKit
import UserNotifications
import Foundation

/// Durable native storage under Application Support/due. The web layer keeps its snapshot, op queue and clock here
/// (one file per key) instead of IndexedDB, which iOS may purge, and the notification-action intents live here too.
enum Storage {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("due", isDirectory: true)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private static let queue = DispatchQueue(label: "due.storage")

    enum Failure: Error, LocalizedError {
        case badKey(String)
        var errorDescription: String? { if case .badKey(let k) = self { return "invalid kv key \(k)" }; return nil }
    }

    private static func url(_ key: String) throws -> URL {
        guard key.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, !key.hasPrefix(".") else { throw Failure.badKey(key) }
        return dir.appendingPathComponent("kv-\(key).json")
    }

    static func get(_ key: String) throws -> String? {
        let u = try url(key)
        return try queue.sync { try? String(contentsOf: u, encoding: .utf8) }
    }

    static func set(_ key: String, _ value: String) throws {
        let u = try url(key)
        try queue.sync { try value.write(to: u, atomically: true, encoding: .utf8) }
    }
}

/// A Done / snooze tap made on a notification. Recorded the instant it happens (the web UI may not be loaded) and
/// applied by the web layer, which then acks it. The web layer computes everything from `tappedAt`.
enum Intents {
    private static let file = Storage.dir.appendingPathComponent("intents.json")
    private static let queue = DispatchQueue(label: "due.intents")

    private static func read() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try! JSONSerialization.jsonObject(with: data)) as! [[String: Any]]
    }
    private static func write(_ list: [[String: Any]]) {
        try! JSONSerialization.data(withJSONObject: list).write(to: file, options: .atomic)
    }

    static func append(action: String, reminderId: String, now: Date = Date()) -> Bool {
        var intent: [String: Any] = ["id": UUID().uuidString, "reminderId": reminderId, "tappedAt": Int(now.timeIntervalSince1970 * 1000)]
        switch action {
        case "done": intent["kind"] = "complete"
        case "snooze-10": intent["kind"] = "snooze"; intent["minutes"] = 10
        case "snooze-60": intent["kind"] = "snooze"; intent["minutes"] = 60
        case "snooze-tomorrow": intent["kind"] = "snooze"; intent["tomorrow"] = true
        default: return false
        }
        queue.sync { write(read() + [intent]) }
        return true
    }

    static func all() -> [[String: Any]] { queue.sync { read() } }
    static func ack(_ ids: [String]) { queue.sync { write(read().filter { !ids.contains($0["id"] as! String) }) } }
}

// MARK: - Registration (kept in this file so the Xcode project needs no new source entry)

/// APNs device-token registration with the Due server, built so a failed attempt is retried and observable without the phone:
/// every step is reported to POST /api/devices/error (shown as `deviceLog` in GET /api/push), and reports that cannot be
/// delivered are queued and sent later.
enum Registration {
    private static let tokenKey = "due.apnsToken"
    private static let postedKey = "due.apnsTokenPosted"
    private static let queueKey = "due.pendingReports"
    private static let d = UserDefaults.standard
    private static let lock = NSLock()

    private static func request(_ path: String, _ body: [String: Any]) -> URLRequest {
        var req = URLRequest(url: URL(string: Baked.server + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(Baked.token)", forHTTPHeaderField: "authorization")
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func send(_ req: URLRequest, done: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err = err { return done(err.localizedDescription) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            done(status == 200 ? nil : "HTTP \(status)")
        }.resume()
    }

    /// Report a registration step. Queued first, then flushed, so nothing is lost if the network is down.
    static func report(_ stage: String, _ message: String) {
        NSLog("due: \(stage): \(message)")
        lock.lock()
        var q = d.array(forKey: queueKey) as? [[String: String]] ?? []
        q.append(["stage": stage, "message": "\(ISO8601DateFormatter().string(from: Date())) \(message)"])
        d.set(Array(q.suffix(50)), forKey: queueKey)
        lock.unlock()
        flushReports()
    }

    static func flushReports() {
        lock.lock()
        let q = d.array(forKey: queueKey) as? [[String: String]] ?? []
        d.removeObject(forKey: queueKey)
        lock.unlock()
        for item in q {
            send(request("/api/devices/error", item)) { err in
                guard err != nil else { return }
                lock.lock()
                d.set((d.array(forKey: queueKey) as? [[String: String]] ?? []) + [item], forKey: queueKey)
                lock.unlock()
            }
        }
    }

    static func didRegister(token: String) {
        d.set(token, forKey: tokenKey)
        d.set(false, forKey: postedKey)
        report("didRegister", "token \(token.prefix(8))...")
        post(token)
    }

    private static func post(_ token: String) {
        send(request("/api/devices", ["token": token, "platform": "ios"])) { err in
            if let err = err {
                d.set(false, forKey: postedKey)
                report("postDeviceFailed", err)
            } else {
                d.set(true, forKey: postedKey)
                report("postDeviceOk", "registered \(token.prefix(8))...")
            }
        }
    }

    /// Called on launch and every time the app becomes active: re-post a token whose last POST failed, and flush queued reports.
    static func retryIfNeeded() {
        if let token = d.string(forKey: tokenKey), !d.bool(forKey: postedKey) { post(token) }
        flushReports()
    }

    static var hasToken: Bool { d.string(forKey: tokenKey) != nil }

    /// Launch diagnostics: the authorization state, and a check that a token callback actually arrived.
    static func watchLaunch(application: UIApplication) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            report("launch", "authorization=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue) hasToken=\(hasToken)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if !hasToken {
                report("noTokenAfter20s", "no didRegister/didFail callback yet; calling registerForRemoteNotifications again")
                application.registerForRemoteNotifications()
            }
        }
    }
}
