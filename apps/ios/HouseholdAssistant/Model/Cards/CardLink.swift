// A link a card carries. Only https, because the phone opens or loads it, and a card with
// any other kind is refused rather than shown without it.

import Foundation

enum CardLink {
    static func https<Key: CodingKey>(forKey key: Key, in container: KeyedDecodingContainer<Key>) throws -> URL? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "a card's links are https")
        }
        return url
    }
}
