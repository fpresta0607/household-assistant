// One person's answer to a reminder by place that would watch them, as a history page
// lists it. The answer stays the gateway's text, so one a later gateway adds is skipped.

import Foundation

struct RoomPlaceAnswer: Decodable, Equatable, Sendable {
    let author: String
    let answer: String
}
