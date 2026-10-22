// A text the assistant drafted for its owner to send from his own iPhone: who it is for,
// as the assistant knows them ("Gia", "Mom"), the words, and maybe an event to send them,
// written as an event card is. The phone finds that person in its own Contacts, attaches the
// event as a calendar file, and nothing goes out until he taps send in Messages.

import Foundation

struct MessageCard: Decodable, Equatable, Sendable {
    let to: String
    let text: String
    let event: EventCard?

    init(to: String, text: String, event: EventCard? = nil) {
        self.to = to
        self.text = text
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case to, text, event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to).trimmingCharacters(in: .whitespacesAndNewlines)
        text = try container.decode(String.self, forKey: .text).trimmingCharacters(in: .whitespacesAndNewlines)
        event = try container.decodeIfPresent(EventCard.self, forKey: .event)
        guard !to.isEmpty, !text.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .to, in: container, debugDescription: "a message needs who it is for and its words")
        }
    }
}
