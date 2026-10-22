// What a conversation's pin on Chats shows without reading its thread: the newest message
// the gateway kept there, as the pin's line says it, how many are unread, and whether
// somebody is typing. The room replaces it only when one of these changes, so a reply
// streaming in, which the pin never shows, does not redraw Chats.

import Foundation

struct ConversationSummary: Equatable, Sendable {
    /// The newest message the gateway has kept. Nil, with no author, in a conversation
    /// that has none.
    let latestId: String?
    let latestAuthor: String?
    /// The latest message's words, or for one with none, what it carries: a call and its
    /// length, a voice note's length, a map. Empty for a photo, a video or a file, which
    /// `previewSymbol` says on its own.
    let preview: String
    /// The SF Symbol for what the latest message carries, when it has no words.
    let previewSymbol: String?
    let unread: Int
    let isTyping: Bool

    /// A conversation with nothing in it and nobody typing.
    static let empty = ConversationSummary(RoomThread(.family), readBy: nil, isTyping: false)

    /// `person` is who the unread count is for, nil until the room knows.
    init(_ thread: RoomThread, readBy person: String?, isTyping: Bool) {
        let latest = thread.messages.last { $0.rev != nil }
        let line = latest.map(Self.line(for:))
        latestId = latest?.id
        latestAuthor = latest?.author
        preview = line?.text ?? ""
        previewSymbol = line?.symbol
        unread = person.map { thread.unreadCount(for: $0) } ?? 0
        self.isTyping = isTyping
    }

    private static func line(for message: RoomMessage) -> (symbol: String?, text: String) {
        let hasWords = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let call = message.call {
            return ("phone.fill", "Call, \(call.length)")
        }
        if let first = message.media.first, !hasWords {
            let length = first.kind == .voice ? first.durationMs.map { VoiceNoteGesture.clock(milliseconds: $0) } : nil
            return (RoomMediaSymbol.name(for: first.kind), length ?? "")
        }
        if let location = message.location, !hasWords {
            return ("location.fill", location.isLive ? "Live location" : "Location")
        }
        return (nil, message.text)
    }
}
