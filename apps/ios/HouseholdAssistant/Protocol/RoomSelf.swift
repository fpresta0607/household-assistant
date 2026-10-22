// Who this phone is to the gateway: its person, and that person's own assistant.

import Foundation

struct RoomSelf: Decodable, Equatable, Sendable {
    let person: String
    let assistant: String
}
