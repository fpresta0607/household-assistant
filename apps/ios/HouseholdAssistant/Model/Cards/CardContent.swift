// What a card shows, one case for each type an assistant may send.

import Foundation

enum CardContent: Equatable, Sendable {
    case table(TableCard)
    case chart(ChartCard)
    case checklist(ChecklistCard)
    case event(EventCard)
    case reminder(ReminderCard)
    case map(MapCard)
    case placeReminder(PlaceReminderCard)
    case email(EmailCard)
    case copy(CopyCard)
    case product(ProductCard)
    case message(MessageCard)
    case cart(CartCard)
    case order(OrderCard)
    case scripture(ScriptureCard)
    case sermon(SermonCard)
    case pocketPiggies(PocketPiggiesCard)
    case sources(SourcesCard)
    case agenda(AgendaCard)

    /// The skill a card of this type always comes from, so it wears that skill's badge
    /// without naming it. Nil for a type any skill, or none, may send.
    var skill: CardSkill? {
        switch self {
        case .scripture:
            return .scripture
        case .sermon:
            return .sermons
        case .pocketPiggies:
            return .pocketpiggies
        case .sources:
            return .web
        case .cart, .order:
            return .lists
        case .table, .chart, .checklist, .event, .reminder, .map, .placeReminder, .email, .copy, .product, .message, .agenda:
            return nil
        }
    }

    /// Whether a card has buttons, links or horizontal scrolling, which VoiceOver must
    /// reach one by one, so the bubble keeps them apart instead of reading it as one.
    var hasControls: Bool {
        switch self {
        case .table, .checklist, .event, .placeReminder, .email, .copy, .product, .message, .cart, .scripture, .sermon, .sources:
            return true
        case .chart, .reminder, .map, .order, .pocketPiggies, .agenda:
            return false
        }
    }

    /// Whether a card of this type is drawn in `conversation`. An order is the buyer's
    /// alone, so one that arrives in the family room is refused.
    func isShown(in conversation: RoomConversation) -> Bool {
        if case .order = self {
            return conversation == .direct
        }
        return true
    }
}
