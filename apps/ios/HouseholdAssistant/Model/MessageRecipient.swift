// Who a message card is for, once the phone has looked in its Contacts: one person, a
// choice of several, nobody by that name, or no access to look.

import Foundation

enum MessageRecipient: Equatable, Sendable {
    case one(MessageContact)
    case several([MessageContact])
    case nobody
    case noAccess

    /// Who `name` is among the contacts the phone found for it, nil when it may not read
    /// Contacts. Contacts finds a name by how it starts, so "Gia" also finds "Giacomo":
    /// a contact the name matches whole wins over one it only starts, and one no text can
    /// reach is left out.
    static func matching(_ name: String, in found: [MessageContact]?) -> MessageRecipient {
        guard let found else {
            return .noAccess
        }
        let reachable = found.filter { $0.address != nil }
        let asked = folded(name)
        let whole = reachable.filter { contact in
            folded(contact.name) == asked || contact.names.contains { folded($0) == asked }
        }
        let candidates = whole.isEmpty ? reachable : whole
        switch candidates.count {
        case 0:
            return .nobody
        case 1:
            return .one(candidates[0])
        default:
            return .several(candidates)
        }
    }

    /// A name as compared: trimmed, and without case or accents.
    private static func folded(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
