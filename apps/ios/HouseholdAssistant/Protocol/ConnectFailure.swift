// What to do when the gateway refuses a `connect`.
//
// The decision reads `error.details.code`, the structured connect-error codes
// in `packages/gateway-protocol/src/connect-error-details.ts`.

import Foundation

enum ConnectFailure: Equatable, Sendable {
    /// Approval is pending on the box; keep knocking with the same credential.
    case waitForApproval(requestId: String?)
    /// The stored device token is no longer good for what was asked; drop it and pair again.
    case discardDeviceTokenAndPairAgain(message: String)
    /// The setup code, or whatever else the phone presented, was not accepted;
    /// a new code from Corey or Denise pairs it again.
    case askForNewSetupCode(message: String)
    case retryLater
    case stop(message: String)

    static func classify(_ error: GatewayErrorShape) -> ConnectFailure {
        switch error.detailCode {
        case "PAIRING_REQUIRED":
            return .waitForApproval(requestId: error.pairingRequestId)
        case "AUTH_DEVICE_TOKEN_MISMATCH", "AUTH_SCOPE_MISMATCH":
            return .discardDeviceTokenAndPairAgain(
                message: "This phone's pairing is no longer valid. Pair it again."
            )
        case "AUTH_BOOTSTRAP_TOKEN_INVALID":
            return .askForNewSetupCode(message: "That code has expired or was already used. Get a new one.")
        case "AUTH_TOKEN_MISMATCH", "AUTH_TOKEN_MISSING", "AUTH_REQUIRED", "AUTH_UNAUTHORIZED":
            return .askForNewSetupCode(message: "The gateway did not accept this phone. Get a new code to pair it again.")
        case "AUTH_RATE_LIMITED":
            return .retryLater
        case "DEVICE_AUTH_SIGNATURE_EXPIRED":
            return .stop(message: "This phone's clock is too far from the gateway's. Check the date and time.")
        case "PROTOCOL_MISMATCH", "CLIENT_VERSION_MISMATCH":
            return .stop(message: "The gateway speaks a different protocol version. Update the app.")
        default:
            return .stop(message: error.message)
        }
    }
}
