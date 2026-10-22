// This phone's address for notifications, and the key they are sealed under.
//
// Apple delivers each notification, so the gateway tells Apple only that there is a new
// message and seals who said what under a key this phone made. The key goes to this
// phone's own gateway over its authenticated connection with the address Apple gave,
// and the notification extension opens it; see HouseholdAssistantNotifications.

import Foundation
import Observation

@MainActor
@Observable
final class PushRegistration {
    struct Registration: Equatable {
        let token: String
        let environment: String
        /// Base64 of the 32-byte key.
        let key: String
    }

    /// Apple's address for this phone, as hex. Nil until Apple has given one.
    private(set) var token: String?
    @ObservationIgnored var onToken: (() -> Void)?

    var registration: Registration? {
        guard let token else {
            return nil
        }
        return Registration(token: token, environment: Self.environment, key: PushKey.loadOrCreate().base64EncodedString())
    }

    /// Where Apple sends: its sandbox for a build from Xcode, production for TestFlight.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        onToken?()
    }
}
