// One rich answer inside an assistant's message: a fenced `steward-card` block holding one
// JSON object, read by its `type`. A card wears the badge and look of the skill that
// answered: the one it names, or the one its type always comes from.

import Foundation

struct StewardCard: Decodable, Equatable, Sendable {
    let content: CardContent
    let skill: CardSkill?

    init(content: CardContent, skill: CardSkill?) {
        self.content = content
        self.skill = skill
    }

    private enum CodingKeys: String, CodingKey {
        case type, skill
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let named = try container.decodeIfPresent(String.self, forKey: .skill).flatMap(CardSkill.init(rawValue:))
        switch try container.decode(String.self, forKey: .type) {
        case "table":
            content = .table(try TableCard(from: decoder))
        case "chart":
            content = .chart(try ChartCard(from: decoder))
        case "checklist":
            content = .checklist(try ChecklistCard(from: decoder))
        case "event":
            content = .event(try EventCard(from: decoder))
        case "reminder":
            content = .reminder(try ReminderCard(from: decoder))
        case "map":
            content = .map(try MapCard(from: decoder))
        case "place-reminder":
            content = .placeReminder(try PlaceReminderCard(from: decoder))
        case "email":
            content = .email(try EmailCard(from: decoder))
        case "copy":
            content = .copy(try CopyCard(from: decoder))
        case "product":
            content = .product(try ProductCard(from: decoder))
        case "message":
            content = .message(try MessageCard(from: decoder))
        case "cart":
            content = .cart(try CartCard(from: decoder))
        case "order":
            content = .order(try OrderCard(from: decoder))
        case "scripture":
            content = .scripture(try ScriptureCard(from: decoder))
        case "sermon":
            content = .sermon(try SermonCard(from: decoder))
        case "pocketpiggies":
            content = .pocketPiggies(try PocketPiggiesCard(from: decoder))
        case "sources":
            content = .sources(try SourcesCard(from: decoder))
        case "agenda":
            content = .agenda(try AgendaCard(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "not a card type this app draws")
        }
        skill = named ?? content.skill
    }
}
