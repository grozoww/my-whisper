import Foundation
import OSLog
import Security

/// The only place an API key is ever written down.
///
/// `CONTRIBUTING.md` makes this a hard rule: keys come from the user at runtime and live in the
/// macOS Keychain, never in a config file, a build setting, or a log line. Nothing in this type
/// returns a key to anywhere it could be persisted a second time — callers read it, send it to the
/// provider that owns it, and drop it.
enum KeychainStore {
    /// One entry per provider. The account string is what shows up in Keychain Access, so it is
    /// written to be recognisable there rather than to be short.
    enum Account: String, CaseIterable {
        case soniox = "Soniox API key"
    }

    private static let service = "com.grozoww.ourwhisper"
    private static let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "keychain")

    static func read(_ account: Account) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                log.error("Keychain read failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ account: Account) -> Bool {
        var query = baseQuery(account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Writing an empty string deletes the entry, so "clear the key" and "save the key" are the
    /// same call from the UI's point of view.
    @discardableResult
    static func write(_ value: String, for account: Account) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(account) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query = baseQuery(account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        // Update first: SecItemAdd on an existing item fails with errSecDuplicateItem, and
        // delete-then-add would leave a window where the key is simply gone.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else {
            log.error("Keychain update failed: \(updateStatus)")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        // The key is only ever needed while the user is at the machine, and the app does not run
        // before first unlock. `ThisDeviceOnly` also keeps it out of iCloud Keychain.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            log.error("Keychain add failed: \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: Account) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}
