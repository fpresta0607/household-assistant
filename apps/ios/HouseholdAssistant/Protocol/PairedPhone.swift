// One of this person's iPhones paired to their own gateway, as the gateway lists it from
// OpenClaw's device list: its device id, the name and model OpenClaw keeps for it, when
// it last connected, and whether it is this phone. Never a key or a token.

import Foundation

struct PairedPhone: Decodable, Equatable, Identifiable, Sendable {
    /// OpenClaw's device id.
    let id: String
    let name: String
    /// The device family the phone gave when it paired, such as `iphone`, when it gave one.
    let model: String?
    /// Milliseconds since 1970, when the gateway has seen it connect.
    let lastSeenAtMs: Int?
    let isThisPhone: Bool
}
