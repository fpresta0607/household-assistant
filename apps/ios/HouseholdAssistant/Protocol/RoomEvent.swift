// The two events the household-app plugin sends: something changed, so catch up; and
// someone is typing.

import Foundation

enum RoomEvent: Equatable, Sendable {
    case changed(rev: Int)
    case typing(conversation: RoomConversation, author: String, isActive: Bool)

    static let changedName = "plugin.household-app.changed"
    static let typingName = "plugin.household-app.typing"

    /// Nil for any other event, and for one of these two that does not parse.
    init?(_ event: GatewayEvent) {
        guard case .room(let room) = event.body else {
            return nil
        }
        self = room
    }

    /// One of the two, read straight from its event's payload as the frame is decoded.
    /// Nil for any other event, and for one of these two that does not parse.
    init?(_ name: String, payload: Decoder) {
        switch name {
        case Self.changedName:
            guard let changed = try? Changed(from: payload) else {
                return nil
            }
            self = .changed(rev: changed.rev)
        case Self.typingName:
            guard
                let typing = try? Typing(from: payload),
                let conversation = RoomConversation(rawValue: typing.conversation)
            else {
                return nil
            }
            self = .typing(conversation: conversation, author: typing.author, isActive: typing.active)
        default:
            return nil
        }
    }

    private struct Changed: Decodable {
        let rev: Int
    }

    /// The conversation stays the gateway's text, so one this version does not know is
    /// skipped rather than failing.
    private struct Typing: Decodable {
        let conversation: String
        let author: String
        let active: Bool
    }
}
