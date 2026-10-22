// Something to copy in one tap: a gate code, an address, a link, a price.

import Foundation

struct CopyCard: Decodable, Equatable, Sendable {
    let label: String?
    let text: String

    init(label: String?, text: String) {
        self.label = label
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case label, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        text = try container.decode(String.self, forKey: .text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "nothing to copy")
        }
    }
}
