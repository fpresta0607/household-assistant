// Something to buy: its name, price and store, a picture, and the page it is sold on.
// The picture and the page must be https, because the phone opens and loads them.

import Foundation

struct ProductCard: Decodable, Equatable, Sendable {
    let name: String
    let price: String?
    let store: String?
    let image: URL?
    let url: URL?

    init(name: String, price: String?, store: String?, image: URL?, url: URL?) {
        self.name = name
        self.price = price
        self.store = store
        self.image = image
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case name, price, store, image, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        price = try container.decodeIfPresent(String.self, forKey: .price)
        store = try container.decodeIfPresent(String.self, forKey: .store)
        image = try CardLink.https(forKey: .image, in: container)
        url = try CardLink.https(forKey: .url, in: container)
    }
}
