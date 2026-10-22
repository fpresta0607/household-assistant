// What was shared in the family room and in this phone's own thread, in one strip under
// the pins on Chats: photos, videos and files, newest first. Voice notes are said, not
// shared, so they stay in their thread.

import Foundation

struct SharedMedia: Identifiable, Equatable, Sendable {
    let media: RoomMedia
    let conversation: RoomConversation
    let author: String
    let sentAt: Date

    var id: String {
        media.id
    }

    /// The newest `limit` attachments the gateway has kept, each once, where it was sent
    /// last. One still uploading has no name the gateway knows yet, so it waits.
    static func latest(in conversations: [(RoomConversation, [RoomMessage])], limit: Int) -> [SharedMedia] {
        let all: [SharedMedia] = conversations.flatMap { conversation, messages in
            messages.filter { $0.rev != nil }.flatMap { message in
                message.media
                    .filter { $0.kind != .voice }
                    .map { SharedMedia(media: $0, conversation: conversation, author: message.author, sentAt: message.sentAt) }
            }
        }
        // Several from one message keep their order.
        let newestFirst = all.enumerated().sorted { first, second in
            first.element.sentAt == second.element.sentAt
                ? first.offset < second.offset
                : first.element.sentAt > second.element.sentAt
        }
        var seen = Set<String>()
        return Array(newestFirst.map(\.element).filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    /// Every photo, video and file in `conversations` whose message holds `query`, in its
    /// words or a file's name (ThreadSearch), newest first, each once.
    static func matching(_ query: String, in conversations: [(RoomConversation, [RoomMessage])]) -> [SharedMedia] {
        let found: [SharedMedia] = conversations.flatMap { conversation, messages -> [SharedMedia] in
            let shared = messages.filter { message in message.rev != nil && message.media.contains { $0.kind != .voice } }
            let byId = Dictionary(shared.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ThreadSearch.matches(of: query, in: shared).flatMap { match -> [SharedMedia] in
                guard let message = byId[match.messageId] else {
                    return []
                }
                return message.media
                    .filter { $0.kind != .voice }
                    .map { SharedMedia(media: $0, conversation: conversation, author: message.author, sentAt: message.sentAt) }
            }
        }
        var seen = Set<String>()
        return found
            .sorted { $0.sentAt > $1.sentAt }
            .filter { seen.insert($0.id).inserted }
    }
}
