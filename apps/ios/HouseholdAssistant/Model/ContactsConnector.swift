// The Contacts connector, which works on this iPhone and never on the gateway: its person's
// own switch, and what iOS lets Steward AI read, everyone or only the people chosen. It is
// connected, with the green dot, only once both say yes. Off until its person turns it on,
// even where iOS already allows Contacts.

import Foundation

struct ContactsConnector: Equatable, Sendable {
    let isOn: Bool
    let access: PhoneAccessState

    /// How many of the people chosen the Contacts page names before it counts the rest.
    private static let namesShown = 3

    var isConnected: Bool {
        isOn && (access == .allowed || access == .limited)
    }

    /// What its switch shows: off while iOS says no, whatever its person chose.
    var isSwitchedOn: Bool {
        isOn && !access.isUpToIOS
    }

    /// The line under its name in Connectors.
    var line: String {
        if access.isUpToIOS {
            return "Off in your iPhone's Settings"
        }
        guard isOn else {
            return "Finds who a text is for"
        }
        switch access {
        case .allowed:
            return "All your contacts"
        case .limited:
            return "Only the people you chose"
        case .notAsked, .denied, .unavailable:
            return "Finds who a text is for"
        }
    }

    /// The people chosen as the Contacts page names them: "Gia, Mom, Mike Rossi and 3 more".
    static func chosen(_ names: [String]) -> String? {
        guard !names.isEmpty else {
            return nil
        }
        let shown = names.prefix(namesShown).joined(separator: ", ")
        let rest = names.count - namesShown
        return rest > 0 ? "\(shown) and \(rest) more" : shown
    }
}
