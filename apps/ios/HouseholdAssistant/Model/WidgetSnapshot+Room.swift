// What the widgets show of the room as this phone holds it: each conversation's newest
// lines and how many are unread, and who is in the room.
//
// Only what the gateway has kept counts. A message on its way, a reply still streaming
// in, a reaction and somebody else reading change nothing here, so none of them reloads
// a widget; the reply does once it lands.

import Foundation

extension WidgetSnapshot {
    /// Lines kept for each conversation: as many as the large widget shows.
    static let lineCount = 5
    /// Where a line's words are cut: more than any widget shows.
    static let lineLength = 160

    /// `rings` are the rings this phone's person picked for assistants' faces, by
    /// participant id.
    mutating func show(
        family: RoomThread,
        direct: RoomThread,
        participants: [RoomParticipant],
        me: RoomSelf,
        rings: [String: RingColor] = [:]
    ) {
        self.me = me.person
        assistant = me.assistant
        faces = FamilyFaces.arranged(participants).map { participant in
            Face(
                id: participant.id,
                name: participant.name,
                isAssistant: participant.kind == .assistant,
                isOwner: participant.isOwner,
                emoji: participant.emoji,
                hasPhoto: participant.avatar != nil,
                ring: participant.kind == .assistant ? rings[participant.id] : nil
            )
        }
        self.family = Self.conversation(family, readBy: me.person)
        self.direct = Self.conversation(direct, readBy: me.person)
    }

    private static func conversation(_ thread: RoomThread, readBy person: String) -> Conversation {
        Conversation(
            lines: thread.messages.filter { $0.rev != nil }.suffix(lineCount).map(line),
            unread: thread.unreadCount(for: person)
        )
    }

    /// A message's words on one line, or when it has none, what it carries. A map says it
    /// is one and never where: a widget can sit on the Lock Screen.
    private static func line(_ message: RoomMessage) -> Line {
        let said = words(of: message.text)
        if said.isEmpty, let location = message.location {
            return Line(id: message.id, author: message.author, text: location.isLive ? "Live location" : "Location", symbol: "location.fill", sentAt: message.sentAt)
        }
        guard said.isEmpty, let first = message.media.first else {
            return Line(id: message.id, author: message.author, text: said, symbol: nil, sentAt: message.sentAt)
        }
        return Line(
            id: message.id,
            author: message.author,
            text: label(for: first),
            symbol: RoomMediaSymbol.name(for: first.kind),
            sentAt: message.sentAt
        )
    }

    /// The Markdown with its cards left out, every run of white space as one space, or
    /// for a message that is only cards, what the first is about.
    private static func words(of text: String) -> String {
        var prose: [String] = []
        var firstCard: CardContent?
        for segment in StewardCardParser.segments(in: text, isStreaming: false) {
            switch segment {
            case .markdown(let markdown), .code(let markdown):
                prose.append(markdown)
            case .card(let card):
                firstCard = firstCard ?? card.content
            case .pendingCard:
                break
            }
        }
        let line = prose.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.isEmpty, let firstCard {
            return headline(of: firstCard)
        }
        return line.count > lineLength ? String(line.prefix(lineLength - 1)) + "\u{2026}" : line
    }

    /// What a card is about. Never what a copy card holds, which may be a gate code, and
    /// a widget can sit on the Lock Screen.
    private static func headline(of card: CardContent) -> String {
        switch card {
        case .table(let table):
            return table.title ?? "Table"
        case .chart(let chart):
            return chart.title ?? "Chart"
        case .checklist(let checklist):
            return checklist.title ?? "Checklist"
        case .event(let event):
            return event.title
        case .reminder(let reminder):
            return reminder.text
        case .map(let map):
            return map.label.map { "Map of \($0)" } ?? "Map"
        case .placeReminder(let reminder):
            return reminder.text
        case .email(let email):
            return email.subject
        case .copy:
            return "Something to copy"
        case .product(let product):
            return product.name
        case .message(let message):
            return "A text for \(message.to)"
        case .cart(let cart):
            return cart.title ?? "Cart"
        case .order(let order):
            return order.title
        case .scripture(let scripture):
            return scripture.reference
        case .sermon(let sermon):
            return sermon.title
        case .pocketPiggies:
            return "PocketPiggies"
        case .sources:
            return "Sources"
        case .agenda(let agenda):
            return agenda.title ?? "Agenda"
        }
    }

    private static func label(for media: RoomMedia) -> String {
        switch media.kind {
        case .voice:
            return "Voice note \u{00B7} " + VoiceNoteGesture.clock(milliseconds: media.durationMs ?? 0)
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .file:
            return media.name ?? "File"
        }
    }
}
