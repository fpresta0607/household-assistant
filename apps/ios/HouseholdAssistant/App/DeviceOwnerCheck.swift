// Asks iOS whether whoever holds this iPhone is its owner, for App Lock: Face ID, with the
// iPhone's passcode when Face ID cannot tell, both shown by iOS itself. The first time,
// iOS asks whether Steward AI may use Face ID, with the usage line from the Info.plist.
// The app learns only whether it passed, and nothing about it leaves the phone.

import Foundation
import LocalAuthentication

enum DeviceOwnerCheck {
    enum Outcome: Sendable {
        /// Face ID or the passcode proved it is the owner.
        case passed
        /// The iPhone has no passcode, so there is nothing to check against.
        case unavailable
        /// Cancelled, failed, or stopped by iOS. A lock stays and offers Unlock.
        case refused
    }

    /// Async and away from the main actor, where the context it makes stays until it is
    /// answered.
    static func run(reason: String) async -> Outcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet ? .unavailable : .refused
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .passed : .refused
        } catch let error as LAError where error.code == .passcodeNotSet {
            return .unavailable
        } catch {
            return .refused
        }
    }
}
