// The connection's secrets, in the Keychain.

import Foundation

@MainActor
final class KeychainCredentialStore: CredentialStore {
    var deviceToken: StoredDeviceToken? {
        get {
            Keychain.data(for: "device-token").flatMap { try? JSONDecoder().decode(StoredDeviceToken.self, from: $0) }
        }
        set {
            Keychain.set(newValue.flatMap { try? JSONEncoder().encode($0) }, for: "device-token")
        }
    }

    /// In memory only: a setup code works once, for minutes, so it has no business
    /// in the Keychain.
    var bootstrapToken: String?

    var appleSignInWait: AppleSignInWait? {
        get {
            Keychain.data(for: "apple-sign-in-wait").flatMap { try? JSONDecoder().decode(AppleSignInWait.self, from: $0) }
        }
        set {
            Keychain.set(newValue.flatMap { try? JSONEncoder().encode($0) }, for: "apple-sign-in-wait")
        }
    }
}
