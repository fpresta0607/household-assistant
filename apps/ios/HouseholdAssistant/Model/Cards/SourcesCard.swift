// The pages a web search answer came from, each a chip named by its title or its site.
// Every link must be https, because the phone opens it.

import Foundation

struct SourcesCard: Decodable, Equatable, Sendable {
    struct Link: Decodable, Equatable, Sendable {
        let url: URL
        let title: String?

        private enum CodingKeys: String, CodingKey {
            case url, title
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let url = try CardLink.https(forKey: .url, in: container) else {
                throw DecodingError.keyNotFound(CodingKeys.url, .init(codingPath: container.codingPath, debugDescription: "a source needs its link"))
            }
            self.url = url
            title = try container.decodeIfPresent(String.self, forKey: .title).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The title the answer gave it, or its site without the "www.".
        var name: String {
            if let title {
                return title
            }
            let host = url.host ?? url.absoluteString
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    let links: [Link]

    private enum CodingKeys: String, CodingKey {
        case links
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decode([Link].self, forKey: .links)
        guard !links.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .links, in: container, debugDescription: "sources need a link")
        }
    }
}
