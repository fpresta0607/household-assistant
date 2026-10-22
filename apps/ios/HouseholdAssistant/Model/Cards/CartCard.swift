// The household's one shared cart, which both assistants add to: each item with who added
// it and who it is for, and the Amazon link that checks them all out. A newer cart with
// the same id takes this one's place in the thread (RoomThread.isCartReplaced). Every link
// and picture must be https, because the phone opens and loads them.

import Foundation

struct CartCard: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let quantity: Int
        /// Who added it.
        let by: String
        /// Who it is for.
        let forPerson: String
        let url: URL?
        let image: URL?

        init(id: String, name: String, quantity: Int, by: String, forPerson: String, url: URL?, image: URL?) {
            self.id = id
            self.name = name
            self.quantity = quantity
            self.by = by
            self.forPerson = forPerson
            self.url = url
            self.image = image
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, quantity, by, url, image
            case forPerson = "for"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
            quantity = try container.decode(Int.self, forKey: .quantity)
            by = try container.decode(String.self, forKey: .by)
            forPerson = try container.decode(String.self, forKey: .forPerson)
            url = try CardLink.https(forKey: .url, in: container)
            image = try CardLink.https(forKey: .image, in: container)
            guard !id.isEmpty, !name.isEmpty, quantity > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "a cart item needs an id, a name and a quantity")
            }
        }
    }

    let id: String
    let title: String?
    let items: [Item]
    /// Nil when no item has an Amazon link to check out with.
    let checkout: URL?

    init(id: String, title: String?, items: [Item], checkout: URL?) {
        self.id = id
        self.title = title
        self.items = items
        self.checkout = checkout
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, items, checkout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        items = try container.decode([Item].self, forKey: .items)
        checkout = try CardLink.https(forKey: .checkout, in: container)
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "a cart needs its id")
        }
    }
}
