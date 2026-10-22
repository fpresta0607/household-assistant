// The two people a phone can be set up for, and the assistant each asks for a code.
//
// Only the onboarding uses this, to say whom to ask and to open that assistant in
// Telegram with `/app` ready to send, and to know where to sign in with Apple. A setup
// code itself says which gateway it is for.

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

    /// The box's tailnet name, from `HOUSEHOLD_GATEWAY_HOST` in the build's xcconfig
    /// (apps/ios/Household.xcconfig, which the gitignored Local.xcconfig overrides).
    /// Outside an app bundle, as under `swift test` on Linux, the checked-in placeholder.
    static let gatewayHost =
        Bundle.main.object(forInfoDictionaryKey: "HouseholdGatewayHost") as? String
        ?? "household.example.ts.net"

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

    /// The assistant's chat in Telegram with `/app` typed in, ready to send.
    var telegramLink: URL {
        let bot: String
        switch self {
        case .franco:
            bot = "Corey_the_man_bot"
        case .gia:
            bot = "Denise_the_woman_bot"
        }
        // Both bot names are fixed ASCII, so this address always parses.
        return URL(string: "https://t.me/\(bot)?text=%2Fapp")!
    }
}
