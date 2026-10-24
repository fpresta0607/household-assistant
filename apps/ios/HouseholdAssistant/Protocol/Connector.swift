// One thing the assistant can reach, by the name a person knows it by, switched on or off
// for this assistant everywhere, and where it stands on this phone's own
// gateway: connected, waiting for its person's sign-in, or unavailable with the reason why.
// For one that signs in, how it does, and the accounts it is signed in with, which the
// gateway lists only for its own person, so each phone shows only its own side.
//
// An older gateway sends only `signIn` and a count of `accounts`. Everything after them is
// read when it is there and worked out from those two when it is not, so this build works
// with either gateway, and the gateway keeps `signIn` as it was for the builds before.

import Foundation

struct Connector: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: ConnectorCategory
    /// A logo's name, or `symbol:` and an SF Symbol's (see `BrandIcon`).
    let icon: String
    let summary: String
    let isOn: Bool
    /// How it signs in, or nil when it needs none or cannot be used here: the gateway's
    /// `signInKind`, or `signIn` from an older gateway that sends no `signInKind`.
    let signInKind: ConnectorSignIn?
    /// How many sign-ins its gateway holds for it, 0 when none.
    let accounts: Int
    /// From an older gateway, connected when it needs no sign-in or the gateway holds one.
    let state: ConnectorState
    /// Why this gateway cannot have it, one line, only while it is unavailable.
    let reason: String?
    /// What the assistant can do with it, two to five plain lines.
    let capabilities: [String]
    let linkedAccounts: [LinkedAccount]
    /// How its provider's page signs in, only when it signs in by OAuth. An older gateway
    /// describes none, since its only OAuth was Google's, which the app has built in.
    let oauth: ConnectorOAuth?

    var isConnected: Bool {
        state == .connected
    }
}

extension Connector: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case icon
        case summary
        case isOn
        case signIn
        case signInKind
        case accounts
        case state
        case reason
        case capabilities
        case linkedAccounts
        case oauth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(ConnectorCategory.self, forKey: .category)
        icon = try container.decode(String.self, forKey: .icon)
        summary = try container.decode(String.self, forKey: .summary)
        isOn = try container.decode(Bool.self, forKey: .isOn)
        // A gateway that knows `signInKind` always sends it, null included, and keeps
        // `signIn` for the builds before, so `signIn` is read only from one that does not.
        if container.contains(.signInKind) {
            signInKind = try container.decodeIfPresent(ConnectorSignIn.self, forKey: .signInKind)
        } else {
            signInKind = try container.decodeIfPresent(ConnectorSignIn.self, forKey: .signIn)
        }
        accounts = try container.decode(Int.self, forKey: .accounts)
        state = try container.decodeIfPresent(ConnectorState.self, forKey: .state)
            ?? (signInKind == nil || accounts >= 1 ? .connected : .available)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        linkedAccounts = try container.decodeIfPresent([LinkedAccount].self, forKey: .linkedAccounts) ?? []
        oauth = try container.decodeIfPresent(ConnectorOAuth.self, forKey: .oauth)
    }
}
