// One person's reaction to one message.

import Foundation

struct RoomReaction: Decodable, Equatable, Hashable, Sendable {
    let author: String
    let emoji: String
}
