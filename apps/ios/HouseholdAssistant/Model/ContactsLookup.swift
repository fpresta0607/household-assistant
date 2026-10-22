// What a message card does about Contacts as it shows, the first time a text the assistant
// drafted needs to know who it is for. Nothing once it knows who or once it was sent, and
// nothing while the Contacts switch in Settings is off. Otherwise it puts iOS's question
// on screen when iOS has never asked, reads when iOS allows it, and says it may not look
// when iOS said no, which iOS never asks again. Nothing else in the app asks for
// Contacts, so iOS never asks at install.

import Foundation

enum ContactsLookup: Equatable, Sendable {
    /// Leave Contacts alone.
    case leave
    /// Ask iOS, then read if it allows it.
    case ask
    case read
    case noAccess

    static func step(for state: MessageCardState, isContactsOn: Bool, access: PermissionStatus) -> ContactsLookup {
        guard isContactsOn, state.recipient == nil, !state.isSent else {
            return .leave
        }
        switch access {
        case .notAsked:
            return .ask
        case .allowed:
            return .read
        case .denied:
            return .noAccess
        }
    }
}
