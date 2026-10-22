// One row of a conversation's thread as its list shows it (ThreadList): a message, with the
// time above it when one belongs there and "Read" under this phone's newest message; or the
// spinner while older messages can still be read, the hello in an empty thread, someone
// typing, which says what this phone's assistant is doing while it works, something shared
// from another app on its way, or a change to the family room's look, among the messages
// at its time. No line of the assistant's steps shows before or around a reply.
//
// A reply is laid out whole once it is complete, never word by word: while it streams in,
// and while its words are made ready to draw, its author's typing row stands in for it.
// Then it takes the typing row's place without a jump and types in from the top, line by
// line (ThreadCollectionCoordinator).
// The room for "Delivered" under this phone's newest message is kept from the moment it is
// sent, so the receipt arriving never moves it.
//
// A row carries everything its view is built from apart from the room's people and the
// app's settings, which the view reads itself. Two rows with equal content draw the same:
// a word streaming into a reply changes no row at all.

import Foundation

struct ThreadRow: Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case older
        case hello
        /// A message, by the bubble it shows in. `occurrence` counts the rows above it with
        /// the same bubble: a late word of a reply the gateway already kept streams under
        /// the kept reply's bubble again, and is a row of its own rather than a second row
        /// with the kept one's id, which the list cannot hold.
        case message(bubble: String, occurrence: Int)
        case typing(String)
        case shared(String)
        case look(String)
    }

    enum Content: Equatable, Sendable {
        case older
        case hello
        case message(Message)
        case typing(Typing)
        case shared(Shared)
        case look(FamilyLookLine)
    }

    /// A message and everything drawn with it in its row.
    struct Message: Equatable, Sendable {
        let message: RoomMessage
        let placement: BubblePlacement
        /// Whether it is the thread's first message, which sits closer to the top.
        let isFirst: Bool
        let repliedTo: RoomMessage?
        /// The carts in it that a later message has replaced (CartReplacements).
        let replacedCarts: Set<String>
        let offersFollowups: Bool
        /// Who has read it, this phone's person aside, under this phone's newest message,
        /// where none reads "Delivered" once the gateway has kept it; nil under every other
        /// message.
        let readers: [String]?
        /// Whether it is lifted for reactions, so its row shows nothing where it was.
        let isLifted: Bool
    }

    /// Someone answering who has not begun their reply.
    struct Typing: Equatable, Sendable {
        let participant: String
        /// What this phone's assistant is busy with while its run uses a tool.
        let activity: AssistantActivity?
    }

    /// Something shared from another app that the room has not sent yet.
    struct Shared: Equatable, Sendable {
        let handoff: ShareHandoff
        let isConnected: Bool
    }

    let id: ID
    let content: Content

    /// The rows of `thread`, top to bottom.
    ///
    /// `typing` is everyone the room says is typing, `activity` what this phone's assistant
    /// is busy with, `readying` the replies that have finished streaming whose words are
    /// still being made ready to draw, by message id, and `lifted` the message lifted for
    /// reactions, if any.
    static func rows(
        of thread: RoomThread,
        me: RoomSelf?,
        assistants: Set<String>,
        typing: [String],
        activity: AssistantActivity?,
        readying: Set<String>,
        shared: [ShareHandoff],
        isConnected: Bool,
        lifted: String?
    ) -> [ThreadRow] {
        let isArriving: (RoomMessage) -> Bool = { $0.status == .streaming || readying.contains($0.id) }
        let list = thread.messages.filter { !isArriving($0) }
        let placements = BubblePlacement.placements(for: list)
        // Under this phone's newest message once it is kept, and while it is being sent, so
        // the receipt's room is there before the receipt is.
        let lastOwn = list.lastIndex { $0.author == me?.person && ($0.rev != nil || $0.status == .sending) }
        // The typing bubble says what this phone's assistant is doing while its run uses a
        // tool, in either conversation.
        let working = activity == nil ? nil : me?.assistant
        // Whoever is answering and has not shown their reply: whoever the room says is
        // typing, and whoever has a reply on its way, which their typing row stands in for.
        // A reply that has finished but is not kept yet has ended its author's typing, which
        // the gateway keeps up until it keeps the reply.
        let finished = Set(list.filter { $0.runId != nil && $0.rev == nil }.map(\.author))
        let arriving = Set(thread.messages.filter(isArriving).map(\.author))
        let answering = Set(typing).subtracting(finished).union(arriving).sorted()
        let offeringFollowups = followupsMessageId(in: thread.messages, of: thread.conversation, me: me)
        let carts = CartReplacements(messages: list, assistants: assistants)
        let messagesById = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [ThreadRow] = []
        if thread.hasOlder {
            rows.append(ThreadRow(id: .older, content: .older))
        }
        if list.isEmpty, isConnected {
            rows.append(ThreadRow(id: .hello, content: .hello))
        }
        var bubblesSeen: [String: Int] = [:]
        var lines = thread.lookLines[...]
        for (index, message) in list.enumerated() {
            while let line = lines.first, line.sentAt < message.sentAt {
                rows.append(ThreadRow(id: .look(line.id), content: .look(line)))
                lines = lines.dropFirst()
            }
            let occurrence = bubblesSeen[message.bubbleId, default: 0]
            bubblesSeen[message.bubbleId] = occurrence + 1
            let row = Message(
                message: message,
                placement: placements[index],
                isFirst: index == 0,
                repliedTo: message.replyTo.flatMap { messagesById[$0] },
                replacedCarts: carts.carts(replacedIn: message.id),
                offersFollowups: message.id == offeringFollowups,
                readers: index == lastOwn ? thread.readers(of: message.id).filter { $0 != me?.person } : nil,
                isLifted: message.id == lifted
            )
            rows.append(ThreadRow(id: .message(bubble: message.bubbleId, occurrence: occurrence), content: .message(row)))
        }
        for line in lines {
            rows.append(ThreadRow(id: .look(line.id), content: .look(line)))
        }
        for who in answering {
            let row = Typing(participant: who, activity: who == working ? activity : nil)
            rows.append(ThreadRow(id: .typing(who), content: .typing(row)))
        }
        for handoff in shared {
            rows.append(ThreadRow(id: .shared(handoff.id), content: .shared(Shared(handoff: handoff, isConnected: isConnected))))
        }
        return rows
    }

    /// The assistant's answer whose follow-ups show under it: the newest message, once
    /// the gateway has kept it, and only in this phone's own thread, since a follow-up is
    /// sent as the person's next message and the family room would all read it.
    private static func followupsMessageId(in list: [RoomMessage], of conversation: RoomConversation, me: RoomSelf?) -> String? {
        guard conversation == .direct, let newest = list.last, newest.rev != nil, newest.author == me?.assistant else {
            return nil
        }
        return newest.id
    }
}
