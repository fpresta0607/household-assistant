// A list the person can tick in the chat. Its id is how a tick reaches the assistant, so
// a list without one is refused rather than drawn with boxes that go nowhere.

import Foundation

struct ChecklistCard: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable {
        let text: String
        let done: Bool
    }

    /// The gateway's limit on a list id.
    static let longestId = 80

    let id: String
    let title: String?
    let items: [Item]

    init(id: String, title: String?, items: [Item]) {
        self.id = id
        self.title = title
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        items = try container.decode([Item].self, forKey: .items)
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty, id.count <= Self.longestId, !items.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "a checklist needs an id and items")
        }
    }
}
