// What a conversation's pin on Chats shows without reading its thread: how many messages
// are unread and whether somebody is typing. The room replaces it only when these change,
// so a reply streaming in, which the pin never shows, does not redraw Chats.

struct ConversationSummary: Equatable, Sendable {
    let unread: Int
    let isTyping: Bool

    /// A conversation with nothing in it and nobody typing.
    static let empty = ConversationSummary(RoomThread(.family), readBy: nil, isTyping: false)

    /// `person` is who the unread count is for, nil until the room knows.
    init(_ thread: RoomThread, readBy person: String?, isTyping: Bool) {
        unread = person.map { thread.unreadCount(for: $0) } ?? 0
        self.isTyping = isTyping
    }
}
