// The key this phone's notifications are sealed under, shared by the app, which hands
// it to the gateway, and the notification extension, which opens what Apple delivers.
//
// It lives in the Keychain under the App Group both share, which iOS treats as a
// Keychain access group, readable after the first unlock so a notification that arrives
// with the phone in a pocket still opens. It never leaves this device.
//
// What the gateway seals (deploy/openclaw/plugins/household-app/push.js) is AES-256-GCM:
// a 12-byte nonce, the ciphertext, then the 16-byte tag, as base64, around JSON with the
// conversation, the message and who said what (NotificationPayload).

import CryptoKit
import Foundation
import Security

enum PushKey {
    static let accessGroup = "group.com.siqstack.stewardai"
    private static let service = "com.siqstack.stewardai.push"
    private static let account = "notification-key"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func load() -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func loadOrCreate() -> Data {
        if let key = load() {
            return key
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        return key
    }

    /// What a sealed notification says, or nil when this phone cannot open it, which
    /// leaves Apple's plain "New message" showing.
    static func open(_ sealed: String) -> NotificationPayload? {
        guard
            let key = load(),
            let bytes = Data(base64Encoded: sealed),
            bytes.count > 28,
            let nonce = try? AES.GCM.Nonce(data: bytes.prefix(12)),
            let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes.dropFirst(12).dropLast(16), tag: bytes.suffix(16)),
            let opened = try? AES.GCM.open(box, using: SymmetricKey(data: key))
        else {
            return nil
        }
        return try? JSONDecoder().decode(NotificationPayload.self, from: opened)
    }
}
