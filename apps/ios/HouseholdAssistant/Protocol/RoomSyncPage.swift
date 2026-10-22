// What `household-app.sync` answers: the changes after a revision, oldest first.

import Foundation

struct RoomSyncPage: Decodable, Equatable, Sendable {
    let entries: [RoomEntry]
    /// The revision to ask from next time.
    let rev: Int
    let hasMore: Bool
    let participants: [RoomParticipant]
    let me: RoomSelf
    /// The gateway session each conversation's turns run in, which is where this
    /// phone's assistant's streamed replies come from.
    let sessionKeys: [RoomConversation: String]
    /// The session this phone's person's own family-room turns run in, whose replies stream
    /// from there. Nil from a gateway that runs them in the room's shared session.
    let ownersFamilySession: String?
    /// The other household's assistant, for her page in the family room. Nil from a
    /// gateway that does not carry her yet.
    let peerAssistant: PeerAssistant?
    /// The family room's own photo, chosen on either phone. Nil while nobody has chosen
    /// one, and from a gateway that does not carry it yet.
    let familyAvatar: RoomMedia?
    /// The family room's look, changed on either phone. Nil while nobody has changed it,
    /// and from a gateway that does not keep one.
    let familyLook: FamilyLook?
    /// When the two assistants' direct line last moved. Nil before its first step, and from
    /// a gateway that has no line.
    let pair: RoomPair?

    private enum CodingKeys: String, CodingKey {
        case entries, rev, hasMore, participants, sessionKeys, ownersFamilySession, peerAssistant, familyAvatar, familyLook, pair
        case me = "self"
    }
}
