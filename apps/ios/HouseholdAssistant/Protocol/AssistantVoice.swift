// A voice the assistant can speak in, with one plain line about how it sounds. The
// gateway speaks a sample in it, so no voice ever needs a key on the phone.

import Foundation

struct AssistantVoice: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
}
