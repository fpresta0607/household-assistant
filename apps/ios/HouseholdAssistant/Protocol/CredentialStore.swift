// Where the connection keeps its secrets.
//
// A protocol because the phone keeps them in the Keychain and the tests keep
// them in memory.

import Foundation

@MainActor
protocol CredentialStore: AnyObject {
    /// Set when the gateway issues one; cleared when the gateway rejects it.
    var deviceToken: StoredDeviceToken? { get set }
    /// A setup code's single-use token, held in memory only until the phone's own
    /// token arrives. Never written anywhere.
    var bootstrapToken: String? { get set }
    /// A sign-in with Apple waiting for the approver, until it pairs or is given up.
    var appleSignInWait: AppleSignInWait? { get set }
}
