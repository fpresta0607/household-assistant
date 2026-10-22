// An assistant's message as plain words, for Copy, Share and a saved transcript: its
// Markdown as written, and each card as the lines it shows, so nobody is handed a card's
// JSON. A block that is not a card this app can read stays the text it is.

import Foundation

enum MessagePlainText {
    static func text(of message: String, calendar: Calendar) -> String {
        StewardCardParser.segments(in: message, isStreaming: false)
            .compactMap { segment -> String? in
                switch segment {
                case .markdown(let text), .code(let text):
                    return text
                case .card(let card):
                    return lines(of: card.content, calendar: calendar)
                case .pendingCard:
                    return nil
                }
            }
            .joined(separator: "\n\n")
    }

    private static func lines(of card: CardContent, calendar: Calendar) -> String {
        let lines: [String]
        switch card {
        case .table(let table):
            lines = [table.title, table.columns.joined(separator: " | ")].compactMap { $0 }
                + table.rows.map { $0.joined(separator: " | ") }
        case .chart(let chart):
            lines = [chart.title].compactMap { $0 } + chart.readings
        case .checklist(let checklist):
            lines = [checklist.title].compactMap { $0 } + checklist.items.map { ($0.done ? "[x] " : "[ ] ") + $0.text }
        case .event(let event):
            lines = [event.title, when(event, calendar: calendar)] + [event.location].compactMap { $0 }
        case .reminder(let reminder):
            lines = [
                "Reminder: " + reminder.text,
                ConversationTranscript.day(reminder.at, calendar: calendar) + ", " + ConversationTranscript.clock(reminder.at, calendar: calendar),
            ]
        case .map(let map):
            lines = [map.label ?? "Map", "\(map.center.latitude), \(map.center.longitude)"]
        case .placeReminder(let reminder):
            let place = reminder.place.label
            lines = ["Reminder by place: " + reminder.text, reminder.when == .arrive ? "On arriving at \(place)" : "On leaving \(place)"]
        case .email(let email):
            lines = [email.plainText]
        case .copy(let copy):
            lines = [copy.label.map { "\($0): \(copy.text)" } ?? copy.text]
        case .product(let product):
            lines = [product.name, product.price, product.store, product.url?.absoluteString].compactMap { $0 }
        case .message(let message):
            lines = ["To \(message.to): \(message.text)"] + (message.event.map { event in
                [event.title, when(event, calendar: calendar)] + [event.location].compactMap { $0 }
            } ?? [])
        case .cart(let cart):
            lines = [cart.title ?? "Cart"] + cart.items.map { "\($0.quantity) \($0.name), for \($0.forPerson), added by \($0.by)" }
        case .order(let order):
            lines = orderLines(of: order, calendar: calendar)
        case .scripture(let scripture):
            lines = [scripture.plainText, scripture.link?.absoluteString].compactMap { $0 }
        case .sermon(let sermon):
            lines = [sermon.title, sermon.quote, sermon.link?.absoluteString].compactMap { $0 }
        case .pocketPiggies(let piggies):
            lines = piggiesLines(of: piggies)
        case .sources(let sources):
            lines = ["Sources:"] + sources.links.map { "\($0.name) \($0.url.absoluteString)" }
        case .agenda(let agenda):
            lines = [agenda.title].compactMap { $0 } + agenda.days.flatMap { day in
                ["\(day.mark.month) \(day.mark.day)"] + day.events.map { "\($0.title), \($0.time ?? "all day")" }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "Friday, October 16, 2026, 3:30 PM to 4:30 PM", with the end's day when it is another.
    private static func when(_ event: EventCard, calendar: Calendar) -> String {
        let start = ConversationTranscript.day(event.start, calendar: calendar) + ", " + ConversationTranscript.clock(event.start, calendar: calendar)
        guard let end = event.end else {
            return start
        }
        let endDay = calendar.isDate(end, inSameDayAs: event.start) ? "" : ConversationTranscript.day(end, calendar: calendar) + ", "
        return start + " to " + endDay + ConversationTranscript.clock(end, calendar: calendar)
    }

    /// "Household order, 3 items: Shipped", then the day it arrives and its masked number.
    private static func orderLines(of order: OrderCard, calendar: Calendar) -> [String] {
        let items = order.items == 1 ? "1 item" : "\(order.items) items"
        let step = order.steps[order.reached - 1].label
        let arriving = order.arriving.flatMap { calendar.date(from: $0) }.map { "Arriving " + ConversationTranscript.day($0, calendar: calendar) }
        return ["\(order.title), \(items): \(step)", arriving, order.order.map { "Order " + $0 }].compactMap { $0 }
    }

    private static func piggiesLines(of card: PocketPiggiesCard) -> [String] {
        switch card {
        case .balance(let total, let piggies):
            return ["Balance: " + CardNumber.money(total)] + piggies.map { "\($0.name): " + CardNumber.money($0.balance) }
        case .budget(let month, let spent, let limit, let daysLeft):
            let left = daysLeft.map { $0 == 1 ? ", 1 day left" : ", \($0) days left" } ?? ""
            return ["\(month) budget: \(CardNumber.money(spent)) of \(CardNumber.money(limit))\(left)"]
        case .spending(let title, let categories):
            return [title ?? "Spending"] + categories.map { "\($0.name): " + CardNumber.money($0.amount) }
        case .goal(let name, let saved, let target, let weekly):
            let pace = weekly.map { ", \(CardNumber.money($0)) a week" } ?? ""
            return ["\(name): \(CardNumber.money(saved)) of \(CardNumber.money(target))\(pace)"]
        }
    }
}
