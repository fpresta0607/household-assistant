// One card in an assistant's bubble, drawn for its type in the look of the skill that
// answered: royal for the calendar, mint for lists. The skill's badge sits above the
// bubble, once for the whole message, so it is not drawn here.

import SwiftUI

struct CardView: View {
    let card: StewardCard
    /// Nil until the gateway has kept the message.
    let messageId: String?
    /// The assistant that wrote it, which decides whose a reminder by place is.
    let author: String
    let conversation: RoomConversation
    /// Whether the card came in a reply that was streaming when the bubble appeared, so it
    /// draws itself in rather than appearing drawn.
    let isArriving: Bool
    /// The carts in this message that a later message has replaced (CartReplacements).
    let replacedCarts: Set<String>

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch card.content {
        case .table(let table):
            TableCardView(table: table)
        case .chart(let chart):
            ChartCardView(chart: chart, isArriving: isArriving)
        case .checklist(let checklist):
            ChecklistCardView(checklist: checklist, messageId: messageId, conversation: conversation, isFromLists: card.skill == .lists)
        case .event(let event):
            EventCardView(event: event, isFromCalendar: card.skill == .calendar)
        case .reminder(let reminder):
            ReminderCardView(reminder: reminder)
        case .map(let map):
            MapCardView(card: map, messageId: messageId)
        case .placeReminder(let reminder):
            PlaceReminderCardView(card: reminder, messageId: messageId, author: author)
        case .email(let email):
            EmailCardView(email: email)
        case .copy(let copy):
            CopyCardView(copy: copy)
        case .product(let product):
            ProductCardView(product: product)
        case .message(let message):
            MessageCardView(card: message, messageId: messageId)
        case .cart(let cart):
            CartCardView(cart: cart, messageId: messageId, conversation: conversation, isReplaced: replacedCarts.contains(cart.id))
        case .order(let order):
            OrderCardView(order: order)
        case .scripture(let scripture):
            ScriptureCardView(scripture: scripture, isArriving: isArriving)
        case .sermon(let sermon):
            SermonCardView(sermon: sermon)
        case .pocketPiggies(let piggies):
            PocketPiggiesCardView(card: piggies, isArriving: isArriving)
        case .sources(let sources):
            SourcesCardView(sources: sources)
        case .agenda(let agenda):
            AgendaCardView(agenda: agenda)
        }
    }
}
