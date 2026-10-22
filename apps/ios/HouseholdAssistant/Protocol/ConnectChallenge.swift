// The payload of `connect.challenge`, the first frame the gateway sends.
//
// `ts` becomes `device.signedAt` and `nonce` is signed and echoed back; the
// gateway rejects a signature whose nonce or timestamp it did not issue.

import Foundation

struct ConnectChallenge: Decodable, Equatable, Sendable {
    let nonce: String
    let ts: Int
}
