// One line of a call's words as the gateway keeps them once the call ended: who said it,
// what they said, and when. Only the words: a call keeps no sound.

import Foundation

struct CallTranscriptLine: Decodable, Equatable, Sendable {
    /// A participant id: the person or their assistant.
    let author: String
    let text: String
    /// Milliseconds since the epoch.
    let at: Int

    var sentAt: Date {
        Date(timeIntervalSince1970: Double(at) / 1000)
    }
}
