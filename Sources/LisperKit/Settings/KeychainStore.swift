import Foundation
import Security

/// Stores the Groq API key in the login keychain.
///
/// The decrypted value is memoised in memory after the first read so the OS
/// keychain is touched at most once per launch — otherwise every dictation
/// (which rebuilds the pipeline) re-reads it and, if the item's ACL doesn't
/// match the running signature, macOS prompts for the login password each time.
public enum KeychainStore {
    private static let service = "com.lucent.lisper"
    private static let account = "groq-api-key"

    private static let lock = NSLock()
    private static var memo: String?   // last known value
    private static var loaded = false  // whether `memo` reflects the keychain

    @discardableResult public static func saveAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        defer { lock.lock(); memo = key.isEmpty ? nil : key; loaded = true; lock.unlock() }
        guard !key.isEmpty else { return true }
        var add = query
        add[kSecValueData as String] = data
        // Available whenever the keychain is unlocked; re-creating the item from the
        // signed app rebinds its ACL to the current signature — that's what makes
        // "Always Allow" finally stick across rebuilds.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func loadAPIKey() -> String? {
        lock.lock()
        if loaded { defer { lock.unlock() }; return memo }
        lock.unlock()

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let value: String?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            value = String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        lock.lock(); memo = value; loaded = true; lock.unlock()
        return value
    }
}
