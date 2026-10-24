// The first household's two people, and the assistant each pairs with.
//
// Only the onboarding uses this, to show whose phone it is and to know where to sign in
// with Apple, and only in a build made for that household (`isBuiltIn`). A build for every
// household knows nobody before it is paired: each phone pairs with the setup link its own
// household's server makes, and a setup code itself says which gateway it is for.

import Foundation

enum HouseholdMember: String, CaseIterable, Identifiable, Sendable {
    case franco, gia

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .franco:
            return "Franco"
        case .gia:
            return "Gia"
        }
    }

    var assistantName: String {
        switch self {
        case .franco:
            return "Corey"
        case .gia:
            return "Denise"
        }
    }

    var assistantEmoji: String {
        switch self {
        case .franco:
            return "\u{1F989}"
        case .gia:
            return "\u{1F338}"
        }
    }

    /// The tailnet name a checkout builds with, which is nobody's box.
    static let placeholderHost = "household.example.ts.net"

    /// The box's tailnet name, from `HOUSEHOLD_GATEWAY_HOST` in the build's xcconfig
    /// (apps/ios/Household.xcconfig, which the gitignored Local.xcconfig overrides).
    /// Outside an app bundle, as under `swift test` on Linux, the checked-in placeholder.
    static let gatewayHost =
        Bundle.main.object(forInfoDictionaryKey: "HouseholdGatewayHost") as? String
        ?? placeholderHost

    /// Whether this build was made for the first household, whose box it knows. Only then
    /// does the onboarding name its people, or a phone sign in with Apple before it is
    /// paired. A build for every household leaves the placeholder in place.
    static var isBuiltIn: Bool {
        namesABox(gatewayHost)
    }

    /// Whether `host` names a box: not empty, not the placeholder, and not the
    /// `<machine>.<tailnet>.ts.net` that Local.xcconfig.example shows.
    static func namesABox(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != placeholderHost && !trimmed.contains("<")
    }

    /// Where this person's assistant answers a phone that signs in with Apple: the box's
    /// tailnet route, the same address a setup code names.
    var gateway: URL {
        let port: Int
        switch self {
        case .franco:
            port = 18789
        case .gia:
            port = 18790
        }
        // A host name and a port, so this address always parses.
        return URL(string: "https://\(Self.gatewayHost):\(port)")!
    }

}
