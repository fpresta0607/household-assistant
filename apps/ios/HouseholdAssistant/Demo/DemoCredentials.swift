#if DEBUG
// The demo's pairing: already approved, and never written to the Keychain.

import Foundation

@MainActor
final class DemoCredentials: CredentialStore {
    var deviceToken: StoredDeviceToken? = StoredDeviceToken(token: "demo")
    var bootstrapToken: String?
    var appleSignInWait: AppleSignInWait?
}
#endif
