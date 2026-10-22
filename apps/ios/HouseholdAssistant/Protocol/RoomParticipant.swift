// Someone in the family room: the two people and the two assistants. The gateway names
// them, each assistant keeps the name and emoji its own gateway gives it, and anyone may
// have a face chosen from Photos.

import Foundation

struct RoomParticipant: Decodable, Equatable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case person, assistant
    }

    let id: String
    let name: String
    let kind: Kind
    /// True for the person this phone belongs to.
    let isOwner: Bool
    var emoji: String?
    /// Their face, a photo chosen on a phone, once somebody has chosen one.
    var avatar: RoomMedia?
}
