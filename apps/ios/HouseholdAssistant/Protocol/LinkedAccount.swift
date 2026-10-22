// One account a connector is signed in with on this phone's own gateway, as its page shows
// it: the provider's name for it, its address, when it was linked, whether it still works,
// what the assistant can do with it, and whether a phone may disconnect it. Never a token,
// a secret or an expiry. The gateway lists only its own person's accounts, so each phone
// sees only its own side.

import Foundation

struct LinkedAccount: Decodable, Equatable, Identifiable, Sendable {
    enum Status: String, Decodable, Sendable {
        case ok
        /// The provider will not renew the sign-in, so it needs signing in again.
        case expired
        /// The last renewal failed for another reason, and the next success clears it.
        case failing
    }

    /// Stable and opaque, such as `gog:app`, `gog:box:1a2b3c4d` or `notion:app`: what Switch
    /// account and Disconnect name.
    let id: String
    /// The provider's display name for the account, its address, or the workspace's name.
    let name: String
    /// Nil when the gateway has none, as for a pasted token or a sign-in set in the gateway's
    /// own env file.
    let email: String?
    /// When it was linked, in milliseconds since 1970, nil for a sign-in set in the env file.
    let linkedAt: Int?
    let status: Status
    /// What the assistant can do with this account, one plain line each.
    let abilities: [String]
    /// False for a sign-in set in the gateway's env file, which only the box changes.
    let canDisconnect: Bool

    var linkedDate: Date? {
        linkedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}
