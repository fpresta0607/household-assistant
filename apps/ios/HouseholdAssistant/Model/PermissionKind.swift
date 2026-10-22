// The three things the first run offers to turn on, in the order it offers them.
// Contacts and photos are not among them: iOS asks for those the first time they
// are used.

import Foundation

enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case notifications, voice, location

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .notifications:
            return "bell.badge.fill"
        case .voice:
            return "mic.fill"
        case .location:
            return "location.fill"
        }
    }

    var title: String {
        switch self {
        case .notifications:
            return "Notifications"
        case .voice:
            return "Microphone and speech"
        case .location:
            return "Location"
        }
    }

    /// One line on why, for the step that asks.
    var reason: String {
        switch self {
        case .notifications:
            return "Know when the family or your assistant writes, even with the app closed."
        case .voice:
            return "Send voice notes and call your assistant."
        case .location:
            return "Off until you turn it on. Then your iPhone tells your own assistant where you are each time you move a fair way or arrive somewhere, for as long as you choose, and tells nobody else."
        }
    }

    /// The steps still worth showing: those iOS has not asked about yet, in order.
    static func toOffer(_ statuses: [PermissionKind: PermissionStatus]) -> [PermissionKind] {
        allCases.filter { (statuses[$0] ?? .notAsked) == .notAsked }
    }
}
