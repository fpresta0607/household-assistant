// A passage of scripture: its reference and translation, the verses with their numbers,
// and the YouVersion link that opens it in the Bible app.

import Foundation

struct ScriptureCard: Decodable, Equatable, Sendable {
    struct Verse: Decodable, Equatable, Sendable {
        let number: Int
        let text: String

        private enum CodingKeys: String, CodingKey {
            case number = "n"
            case text
        }
    }

    let reference: String
    let translation: String
    let verses: [Verse]
    let link: URL?

    private enum CodingKeys: String, CodingKey {
        case reference, translation, verses, link
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reference = try container.decode(String.self, forKey: .reference)
        translation = try container.decode(String.self, forKey: .translation)
        verses = try container.decode([Verse].self, forKey: .verses)
        let suppliedLink = try container.decodeIfPresent(String.self, forKey: .link)
        if let suppliedLink, !suppliedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            link = try CardLink.https(forKey: .link, in: container)
        } else {
            link = BiblePassageLink.url(reference: reference, translation: translation)
        }
        guard !verses.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .verses, in: container, debugDescription: "a passage needs its verses")
        }
    }

    /// The passage to copy or share: its reference, then its verses with their numbers.
    var plainText: String {
        "\(reference) (\(translation))\n" + verses.map { "\($0.number) \($0.text)" }.joined(separator: " ")
    }
}
