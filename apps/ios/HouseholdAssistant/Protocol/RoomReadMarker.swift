// How far one participant has read in a conversation.

import Foundation

struct RoomReadMarker: Decodable, Equatable, Sendable {
    let author: String
    let messageId: String
}
