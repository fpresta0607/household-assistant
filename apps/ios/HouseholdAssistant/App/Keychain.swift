// Generic-password items in this app's Keychain.
//
// Items are readable after the first unlock, so a Siri request with the phone
// in a pocket can still reach the assistant, and they never leave this device:
// not in a backup, not through iCloud Keychain.

import Foundation
import Security

enum Keychain {
    private static let service = "com.siqstack.stewardai.gateway"

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    /// Stores `data`, or removes the item when `data` is nil.
    static func set(_ data: Data?, for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let data else {
            return
        }
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
