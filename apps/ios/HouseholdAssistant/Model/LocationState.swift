// Whether this iPhone shares where it is, the one reading every screen that says so uses:
// the Location row in Settings and in Account show its label, and Location shows its
// sentence under its switch. The sentence always starts with the label, so the screens
// cannot say different things.
//
// It comes from iOS's permission, the app's own switch and whether the gateway still has a
// position, so a change to any of them shows on every screen at once. Account once showed
// iOS's permission alone there, "On" once iOS allowed While Using, beside a Location page
// whose switch was off.
//
// It reads no clock: a share whose time is up is ended by the app at that moment, so every
// screen changes together then rather than each at the moment it was drawn.

import Foundation

enum LocationState: Equatable, Sendable {
    /// iOS does not let Steward AI use location, so nothing is measured or sent, whatever
    /// the app's own switch says.
    case notAllowed(isStillHeld: Bool)
    case off(isStillHeld: Bool)
    case paused(isStillHeld: Bool)
    case sharing(LocationSharing)

    /// `isHeldByGateway` is true from the moment a position is sent until a stop reaches the
    /// gateway. While nothing is shared, it means the gateway still has the last position.
    init(permission: PermissionStatus, sharing: LocationSharing?, isHeldByGateway: Bool) {
        // Only a no from iOS overrides the switch: before iOS has been read or asked, the
        // switch is all there is to go on.
        guard permission != .denied else {
            self = .notAllowed(isStillHeld: isHeldByGateway)
            return
        }
        switch sharing {
        case nil:
            self = .off(isStillHeld: isHeldByGateway)
        case let sharing? where sharing.isPaused:
            self = .paused(isStillHeld: isHeldByGateway)
        case let sharing?:
            self = .sharing(sharing)
        }
    }

    /// A word or two for the end of a row, short enough never to be cut off there.
    var label: String {
        switch self {
        case .notAllowed:
            return "Not allowed"
        case .off:
            return "Off"
        case .paused:
            return "Paused"
        case .sharing:
            return "Sharing"
        }
    }

    /// What it means, starting with `label`: with whom and until when, or why nothing is
    /// shared and whether the assistant still has where its person was.
    func sentence(assistant: String) -> String {
        let forgets = "\(assistant) forgets where you were once this iPhone gets through."
        switch self {
        case .notAllowed(let isStillHeld):
            return isStillHeld
                ? "Not allowed in iOS Settings. \(forgets)"
                : "Not allowed in iOS Settings, so \(assistant) does not know where you are."
        case .off(let isStillHeld):
            return isStillHeld ? "Off. \(forgets)" : "Off. \(assistant) does not know where you are."
        case .paused(let isStillHeld):
            return isStillHeld ? "Paused. \(forgets)" : "Paused. \(assistant) has forgotten where you were."
        case .sharing(let sharing):
            let who = sharing.audience == .family ? "\(assistant) and the family room" : assistant
            return "Sharing with \(who) \(sharing.endWords)."
        }
    }
}
