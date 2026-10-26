import Foundation
import Security

/// The signed-in user's bearer token, in a keychain access group shared by the app and the notification content extension
/// (the extension runs in its own process and calls the server directly). Compiled into both targets.
enum Keychain {
    /// Must match keychain-access-groups in DueApp.entitlements and DueNCE.entitlements ($(AppIdentifierPrefix) = team id).
    static let group = "J66WVM2DTX.com.oliverullman.due.shared"
    private static let service = "due.auth"

    struct Failure: Error, LocalizedError {
        let op: String
        let status: OSStatus
        var errorDescription: String? { "keychain \(op) failed: OSStatus \(status)" }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { fatalError("keychain read \(account) failed: OSStatus \(status)") }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) throws {
        SecItemDelete(query(account) as CFDictionary) // errSecItemNotFound is the normal first-save case
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock: the extension and background pushes run while the phone is locked.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(op: "add \(account)", status: status) }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(op: "delete \(account)", status: status) }
    }

    static var token: String? { get("token") }

    static func saveLogin(token: String, username: String) throws {
        try set("token", token)
        try set("username", username)
    }

    static func clearLogin() throws {
        try remove("token")
        try remove("username")
    }
}
