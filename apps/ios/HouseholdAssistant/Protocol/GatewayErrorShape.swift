// The `error` member of a failed response.
//
// `code` is the coarse error (`NOT_PAIRED`, `INVALID_REQUEST`); the connect
// errors the app acts on carry a finer `details.code` (`PAIRING_REQUIRED`,
// `AUTH_SCOPE_MISMATCH`), which is what reconnect decisions read.

import Foundation

struct GatewayErrorShape: Codable, Equatable, Sendable, Error {
    let code: String
    let message: String
    let details: JSONValue?

    var detailCode: String? {
        details?["code"]?.stringValue
    }

    /// The pending pairing request the operator approves on the box.
    var pairingRequestId: String? {
        details?["requestId"]?.stringValue
    }
}
