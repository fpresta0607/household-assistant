// What `household-app.history` answers: one conversation's messages before a revision,
// oldest first, with each one's reactions, how each approval card among them ended, each
// live map's newest move, each answer to a reminder by place, what each voice note said as
// the gateway heard it, everyone's read markers, and the changes to the family room's look
// made among them.

import Foundation

struct RoomHistoryPage: Decodable, Equatable, Sendable {
    let messages: [RoomEntry]
    let hasMore: Bool
    let reactions: [String: [RoomReaction]]
    /// How each approval card on the page ended, by message id, as the gateway spells it.
    /// Nil from a gateway that shows no approvals.
    let approvals: [String: String]?
    /// Each live map's newest move on the page, by message id. Nil from a gateway with no maps.
    let lives: [String: RoomLive]?
    /// Who answered each reminder by place on the page, by message id.
    let places: [String: [RoomPlaceAnswer]]?
    /// What each voice note on the page said, by message id, as the gateway heard it. Nil
    /// from a gateway that hears no voice notes.
    let transcripts: [String: String]?
    let reads: [RoomReadMarker]
    let participants: [RoomParticipant]
    let me: RoomSelf
    let sessionKeys: [RoomConversation: String]
    /// The person's own session of the family room, as on the sync page.
    let ownersFamilySession: String?
    /// The family room's own photo, as on the sync page.
    let familyAvatar: RoomMedia?
    /// The changes to the family room's look made among the page's messages, as entries.
    /// Nil from a gateway that keeps no look.
    let looks: [RoomEntry]?
    /// The family room's look, as on the sync page.
    let familyLook: FamilyLook?

    private enum CodingKeys: String, CodingKey {
        case messages, hasMore, reactions, approvals, lives, places, transcripts, reads, participants, sessionKeys, ownersFamilySession, familyAvatar
        case looks, familyLook
        case me = "self"
    }
}
