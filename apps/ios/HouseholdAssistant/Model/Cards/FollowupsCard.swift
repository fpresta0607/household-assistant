// What the person is likely to say next, offered under an assistant's answer as chips
// rather than drawn in its bubble: a tap sends a chip's words as their next message.
// At most three are offered, each with an optional icon from a short list.

import Foundation

struct FollowupsCard: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable {
        enum Icon: String, Sendable {
            case reminder, calendar, list, message, search
        }

        let text: String
        /// Nil when the answer named none, or one the app does not know.
        let icon: Icon?

        private enum CodingKeys: String, CodingKey {
            case text, icon
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "a follow-up needs words")
            }
            icon = try container.decodeIfPresent(String.self, forKey: .icon).flatMap(Icon.init(rawValue:))
        }

        /// The SF Symbol on its chip: sparkles when it has no icon.
        var symbol: String {
            switch icon {
            case .reminder: return "bell"
            case .calendar: return "calendar"
            case .list: return "checklist"
            case .message: return "message"
            case .search: return "magnifyingglass"
            case nil: return "sparkles"
            }
        }
    }

    static let type = "followups"
    static let most = 3

    let items: [Item]

    private enum CodingKeys: String, CodingKey {
        case type, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.type else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "not follow-ups")
        }
        items = Array(try container.decode([Item].self, forKey: .items).prefix(Self.most))
        guard !items.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: container, debugDescription: "follow-ups need one to offer")
        }
    }
}
