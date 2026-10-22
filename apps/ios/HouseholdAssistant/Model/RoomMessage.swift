// One bubble in a household-app conversation: a person's or an assistant's message,
// with the reactions it has gathered, a map a person shared, with its newest move, or a
// call with the assistant, once it ended.

import Foundation

struct RoomMessage: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Said on this phone, not yet kept by the gateway.
        case sending
        /// Said on this phone while the link was down: it goes out by itself once it is back.
        case waiting
        case sent
        /// The send was refused or never arrived, or a streamed reply broke off.
        case failed(String)
        /// An assistant's reply still arriving.
        case streaming
    }

    let id: String
    /// The bubble it shows in: its own id, or for a reply kept after it streamed in, the id
    /// it streamed under, so the bubble that grew with its words stays and only settles.
    var bubbleId: String
    /// A participant id.
    let author: String
    var text: String
    var media: [RoomMedia]
    var replyTo: String?
    var sentAt: Date
    var status: Status
    /// Nil until the gateway has kept it.
    var rev: Int?
    var reactions: [RoomReaction] = []
    /// What a person's voice note said, as the gateway heard it; nil until it has.
    var heard: String?
    var runId: String?
    /// The step an assistant's approval card waits on; nil on every other message.
    var approval: RoomApproval?
    /// What an assistant's run changed, each a chip under its answer.
    var did: [AssistantChange]
    /// Where the person was, on a map they shared; nil on every other message.
    var location: SharedLocation?
    /// A live map's newest move, or its stop.
    var live: RoomLive?
    /// Where a live map last moved to, kept when a stop with no position follows.
    var lastPosition: LocationReport.Position?
    /// A call with the assistant that ended; nil on every other message.
    var call: RoomCall?

    init(
        id: String,
        author: String,
        text: String,
        media: [RoomMedia],
        replyTo: String?,
        sentAt: Date,
        status: Status,
        rev: Int? = nil,
        runId: String? = nil,
        approval: RoomApproval? = nil,
        did: [AssistantChange] = [],
        location: SharedLocation? = nil
    ) {
        self.id = id
        bubbleId = id
        self.author = author
        self.text = text
        self.media = media
        self.replyTo = replyTo
        self.sentAt = sentAt
        self.status = status
        self.rev = rev
        self.runId = runId
        self.approval = approval
        self.did = did
        self.location = location
    }

    init(_ entry: RoomEntry) {
        self.init(
            id: entry.id,
            author: entry.author,
            text: entry.text ?? "",
            media: entry.media ?? [],
            replyTo: entry.replyTo,
            sentAt: entry.sentAt,
            status: .sent,
            rev: entry.rev,
            runId: entry.runId,
            approval: entry.approval,
            did: entry.did,
            location: entry.location
        )
        call = RoomCall(entry)
    }

    /// Takes a live map's move if it is newer than the one shown.
    mutating func move(_ moved: RoomLive) {
        guard live.map({ moved.at > $0.at }) ?? true else {
            return
        }
        live = moved
        if let position = moved.position {
            lastPosition = position
        }
    }

    /// Where a shared map shows its person now: the newest move, or where they shared it.
    var shownPosition: LocationReport.Position? {
        lastPosition ?? location?.position
    }
}
