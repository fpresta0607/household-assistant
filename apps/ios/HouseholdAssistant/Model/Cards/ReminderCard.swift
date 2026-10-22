// Something the assistant will remind its person of, and when.

import Foundation

struct ReminderCard: Decodable, Equatable, Sendable {
    let text: String
    let at: Date

    init(text: String, at: Date) {
        self.text = text
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case text, at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text).trimmingCharacters(in: .whitespacesAndNewlines)
        at = try CardMoment.date(forKey: .at, in: container)
        guard !text.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "a reminder needs its words")
        }
    }
}
