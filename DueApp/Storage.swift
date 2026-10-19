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
