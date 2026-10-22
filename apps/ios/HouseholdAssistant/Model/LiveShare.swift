// A live map this phone shared and still moves: which message, in which conversation, and
// when it stops by itself. Kept across launches, so a share outlives the app being closed.

import Foundation

struct LiveShare: Codable, Equatable, Sendable {
    let messageId: String
    let conversation: RoomConversation
    let until: Date

    func isOver(at now: Date) -> Bool {
        now >= until
    }
}
