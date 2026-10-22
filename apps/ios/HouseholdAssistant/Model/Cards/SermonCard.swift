// A sermon from the household's own archive: its title, a line from it, how long it runs,
// and the page it can be read on. The page must be https, because the phone opens it.

import Foundation

struct SermonCard: Decodable, Equatable, Sendable {
    let title: String
    let quote: String?
    let minutes: Int?
    let link: URL?

    init(title: String, quote: String?, minutes: Int?, link: URL?) {
        self.title = title
        self.quote = quote
        self.minutes = minutes
        self.link = link
    }

    private enum CodingKeys: String, CodingKey {
        case title, quote, minutes, link
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        quote = try container.decodeIfPresent(String.self, forKey: .quote)
        minutes = try container.decodeIfPresent(Int.self, forKey: .minutes)
        link = try CardLink.https(forKey: .link, in: container)
        guard !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: "a sermon needs its title")
        }
        if let minutes, minutes <= 0 {
            throw DecodingError.dataCorruptedError(forKey: .minutes, in: container, debugDescription: "a sermon runs a while")
        }
    }
}
