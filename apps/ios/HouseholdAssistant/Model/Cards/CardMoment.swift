// A moment a card names: ISO 8601 with its offset, so it is exact whatever time zone the
// phone is in, with or without fractions of a second.
//
// Read with two styles made once, not a formatter made for each moment: a card is decoded
// every time a message is read. A format style is a value and safe to share between
// threads, which Foundation's ISO 8601 formatter is not documented to be.

import Foundation

enum CardMoment {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func date<Key: CodingKey>(forKey key: Key, in container: KeyedDecodingContainer<Key>) throws -> Date {
        let text = try container.decode(String.self, forKey: key)
        guard let date = (try? plain.parse(text)) ?? (try? fractional.parse(text)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not an ISO 8601 time with an offset")
        }
        return date
    }
}
