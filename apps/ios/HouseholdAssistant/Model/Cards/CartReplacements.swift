// Which carts in a thread a newer one has taken the place of. A cart's card gives way to
// a later message from an assistant that carries a cart with the same id, so the thread
// shows the cart as it is now (CartCardView), and a cart still arriving counts once its
// block has closed. A cart in a message the gateway has not kept yet is never replaced.
//
// Worked out once each time the thread changes, by walking it from its newest message
// back, rather than by every cart card reading every message after its own.

import Foundation

struct CartReplacements: Equatable, Sendable {
    /// By message id, the carts it carries that a later assistant's message carries again.
    private var replaced: [String: Set<String>] = [:]

    init(messages: [RoomMessage], assistants: Set<String>) {
        var later: Set<String> = []
        for message in messages.reversed() where assistants.contains(message.author) {
            let carts = Self.carts(in: message)
            let replacedHere = carts.intersection(later)
            if message.rev != nil, !replacedHere.isEmpty {
                replaced[message.id] = replacedHere
            }
            later.formUnion(carts)
        }
    }

    /// The ids of the carts in `messageId` that a later message has replaced.
    func carts(replacedIn messageId: String) -> Set<String> {
        replaced[messageId] ?? []
    }

    private static func carts(in message: RoomMessage) -> Set<String> {
        guard message.text.contains(StewardCardParser.fence) else {
            return []
        }
        var ids: Set<String> = []
        for case .card(let card) in StewardCardParser.segments(in: message.text, isStreaming: message.status == .streaming) {
            if case .cart(let cart) = card.content {
                ids.insert(cart.id)
            }
        }
        return ids
    }
}
