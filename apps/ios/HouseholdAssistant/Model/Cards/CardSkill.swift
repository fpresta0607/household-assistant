// The skill a card says answered it, for the small badge above the card. A name this app
// does not know is no badge rather than a refused card.

import Foundation

enum CardSkill: String, CaseIterable, Sendable {
    case scripture, sermons, pocketpiggies, calendar, lists, web

    var title: String {
        switch self {
        case .scripture:
            return "Scripture"
        case .sermons:
            return "Sermons"
        case .pocketpiggies:
            return "PocketPiggies"
        case .calendar:
            return "Calendar"
        case .lists:
            return "Lists"
        case .web:
            return "Web search"
        }
    }
}
