// One change in the app's conversations, as the household-app plugin reports it: a
// message, a reaction, a read marker, how an approval card ended, a live map's newest
// move, a person's answer to a reminder by place, a call with the assistant, kept as
// one entry with its words once it ended, what a person's voice note said, as the
// gateway heard it, or a person's change to the family room's look. Each carries the
// revision it was made at, and the phone catches up by asking for what came after the
// last one it saw.

import Foundation

struct RoomEntry: Decodable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case message, reaction, read, approval, live, place, call, transcript, look
        /// A kind a later gateway adds. Kept and ignored rather than failing the page.
        case unknown
    }

    let id: String
    let rev: Int
    let kind: Kind
    /// `family` or `direct`, kept as the gateway's text so an unknown one is skipped.
    let conversation: String
    /// A participant id: a person or an assistant.
    let author: String
    /// Milliseconds since the epoch, on the author's clock.
    let at: Int
    let text: String?
    let media: [RoomMedia]?
    let replyTo: String?
    /// The assistant run a reply came from, which is how its streamed text is matched.
    let runId: String?
    /// What a reaction, a read marker, an approval's end or a voice note's words are about.
    let messageId: String?
    /// What a person's voice note said, as the gateway heard it.
    let words: String?
    /// A reaction's emoji; nil when the reaction was taken back.
    let emoji: String?
    /// The step an approval card waits on. Nil on any other message, and on a card the
    /// gateway described in a way this version cannot read, which then shows as words.
    let approval: RoomApproval?
    /// How an approval card ended, as the gateway spells it.
    let state: String?
    /// What an assistant's run changed, for the chips under its answer, without any item
    /// this version cannot read. Empty on anything else.
    let did: [AssistantChange]
    /// Where a person was, on a map they shared.
    let location: SharedLocation?
    /// A live map's newest move. Nil on a move that stopped it.
    let position: LocationReport.Position?
    /// A person's answer to a reminder by place. Nil for one a later gateway adds.
    let answer: PlaceAnswer?
    /// When a call ended, in milliseconds since the epoch; `at` is when it started.
    let endedAt: Int?
    /// The assistant a call was with.
    let callee: String?
    /// The messages a call's words were said in, which the gateway folded into it.
    let turnIds: [String]
    /// What was said on a call, in order, without any line this version cannot read.
    let transcript: [CallTranscriptLine]
    /// Whether the gateway kept only the start of a long call's words.
    let isCut: Bool
    /// What a change to the family room's look changed. Nil on anything else, and on a
    /// change a later gateway adds, which then shows no line.
    let lookChange: FamilyLookChange?

    private enum CodingKeys: String, CodingKey {
        case id, rev, kind, conversation, author, at, text, media, replyTo, runId, messageId, words, emoji, approval, state, did
        case location, position, answer
        case endedAt, turnIds, transcript, isCut
        case change, ring, appearance, background
        case callee = "with"
    }

    /// One item of a list, or nil when this version cannot read it.
    private struct Readable<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        rev = try container.decode(Int.self, forKey: .rev)
        kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .unknown
        conversation = try container.decode(String.self, forKey: .conversation)
        author = try container.decode(String.self, forKey: .author)
        at = try container.decode(Int.self, forKey: .at)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        media = try container.decodeIfPresent([RoomMedia].self, forKey: .media)
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        words = try container.decodeIfPresent(String.self, forKey: .words)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        approval = try? container.decodeIfPresent(RoomApproval.self, forKey: .approval)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        did = (try? container.decodeIfPresent([Readable<AssistantChange>].self, forKey: .did))?.compactMap(\.value) ?? []
        location = try container.decodeIfPresent(SharedLocation.self, forKey: .location)
        position = try container.decodeIfPresent(LocationReport.Position.self, forKey: .position)
        answer = try? container.decodeIfPresent(PlaceAnswer.self, forKey: .answer)
        endedAt = try container.decodeIfPresent(Int.self, forKey: .endedAt)
        callee = try container.decodeIfPresent(String.self, forKey: .callee)
        turnIds = try container.decodeIfPresent([String].self, forKey: .turnIds) ?? []
        transcript = (try? container.decodeIfPresent([Readable<CallTranscriptLine>].self, forKey: .transcript))?.compactMap(\.value) ?? []
        isCut = try container.decodeIfPresent(Bool.self, forKey: .isCut) ?? false
        lookChange = kind == .look ? Self.lookChange(in: container) : nil
    }

    private static func lookChange(in container: KeyedDecodingContainer<CodingKeys>) -> FamilyLookChange? {
        switch try? container.decodeIfPresent(String.self, forKey: .change) {
        case "photo":
            return .photo
        case "color":
            return .color(try? container.decodeIfPresent(RingColor.self, forKey: .ring))
        case "appearance":
            guard let appearance = (try? container.decodeIfPresent(String.self, forKey: .appearance)).flatMap(FamilyLook.Appearance.init(rawValue:)) else {
                return nil
            }
            let background = (try? container.decodeIfPresent(String.self, forKey: .background)).flatMap(ChatBackground.init(rawValue:))
            return .appearance(appearance, background: background)
        default:
            return nil
        }
    }

    /// The line a change to the family room's look shows as, or nil for any other entry.
    var lookLine: FamilyLookLine? {
        lookChange.map { FamilyLookLine(id: id, author: author, sentAt: sentAt, rev: rev, change: $0) }
    }

    var sentAt: Date {
        Date(timeIntervalSince1970: Double(at) / 1000)
    }

    /// Nil for an end a later gateway adds, which is left to that gateway's app.
    var approvalOutcome: RoomApproval.Outcome? {
        state.flatMap(RoomApproval.Outcome.init(rawValue:))
    }

    var roomConversation: RoomConversation? {
        RoomConversation(rawValue: conversation)
    }
}
