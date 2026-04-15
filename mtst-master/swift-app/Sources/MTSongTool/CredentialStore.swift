import Foundation
import Security

/// Credential storage — always uses the system Keychain (encrypted at rest).
///
/// Passwords are stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly so they are
/// inaccessible when the Mac is locked and never leave the device.
/// On first load, any legacy plain-text UserDefaults entries are silently migrated into
/// Keychain and deleted.
struct CredentialStore {

    static let backOfficePasswordKey  = "mtst.backoffice.password"
    static let nolanRyanPasswordKey   = "mtst.nolanryan.password"
    static let audioShakeAPIKeyKey    = "mtst.audioshake.apikey"

    private static let udPrefix = "mtst_cred_"

    // MARK: - Public API

    static func save(key: String, value: String) {
        saveToKeychain(key: key, value: value)
        UserDefaults.standard.removeObject(forKey: udPrefix + key)
    }

    static func load(key: String) -> String? {
        if let val = loadFromKeychain(key: key) { return val }
        // One-time migration: move any legacy plain-text UserDefaults entry into Keychain.
        if let val = UserDefaults.standard.string(forKey: udPrefix + key) {
            saveToKeychain(key: key, value: val)
            UserDefaults.standard.removeObject(forKey: udPrefix + key)
            return val
        }
        return nil
    }

    /// Clears credentials from both stores for the given key.
    static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: udPrefix + key)
        deleteFromKeychain(key: key)
    }

    // MARK: - Keychain helpers

    private static func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteFromKeychain(key: key)

        // nil trusted-app ACL: any build of this app can read without a per-build prompt.
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly: encrypted at rest; inaccessible when
        // the Mac is locked; never synced to iCloud Keychain or transferred to another device.
        var access: SecAccess?
        SecAccessCreate("MT Song Tool" as CFString, nil, &access)

        var query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      "com.multitracks.MTSongTool",
            kSecAttrAccount:      key,
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if let access { query[kSecAttrAccess] = access }
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadFromKeychain(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "com.multitracks.MTSongTool",
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func deleteFromKeychain(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "com.multitracks.MTSongTool",
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
