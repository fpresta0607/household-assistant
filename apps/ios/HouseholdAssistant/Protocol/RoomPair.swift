// The two assistants' direct line as every sync and history page carries it once the line
// has any step: when it last moved, which the family room shows quietly.

import Foundation

struct RoomPair: Decodable, Equatable, Sendable {
    /// Milliseconds since the epoch.
    let lastAt: Int
}
