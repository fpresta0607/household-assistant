// When this phone is told about a conversation: everything, only when its person or
// their assistant is named, or never. Each phone chooses for itself, and its gateway's
// push follows the choice.

import Foundation

enum NotificationChoice: String, Codable, CaseIterable, Sendable {
    case all, mentions, off

    var label: String {
        switch self {
        case .all:
            return "All"
        case .mentions:
            return "When mentioned"
        case .off:
            return "Off"
        }
    }
}
