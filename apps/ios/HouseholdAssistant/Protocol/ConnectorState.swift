// Where a connector stands on this phone's own gateway: `connected` once the assistant can
// use it, which one that needs no sign-in always is, `available` while it waits for its
// person to sign in, and `unavailable` when this gateway cannot have it, with a reason.
// Connectors lists them in this order, so the connected ones are on top.

import Foundation

enum ConnectorState: String, Decodable, CaseIterable, Sendable {
    case connected
    case available
    case unavailable

    /// Over its group in Connectors. The connected ones have none, since each of their rows
    /// leads with the green dot instead of the word.
    var title: String? {
        switch self {
        case .connected:
            return nil
        case .available:
            return "Not connected"
        case .unavailable:
            return "Unavailable"
        }
    }
}
