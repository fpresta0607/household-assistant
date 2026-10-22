// Credentials held in memory, for the connection tests.

import Foundation
@testable import HouseholdAssistant

@MainActor
final class MemoryCredentialStore: CredentialStore {
    var deviceToken: StoredDeviceToken?
    var bootstrapToken: String?
    var appleSignInWait: AppleSignInWait?

    init(deviceToken: StoredDeviceToken? = nil, bootstrapToken: String? = nil) {
        self.deviceToken = deviceToken
        self.bootstrapToken = bootstrapToken
    }
}
