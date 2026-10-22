// What a long press on a notification offers: a reply typed in place, and three
// reactions. The app answers the one chosen the way the composer and the reaction bar
// send (AppModel.answer).
//
// The gateway names each notification's category after its conversation (push.js), so
// the reply field can say where the words go.

import Foundation

enum NotificationActions {
    static let reply = "reply"
    /// A heart, a thumbs up and a laugh, from the reaction bar.
    static let reactions = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F602}"]
    static let familyName = "The Fam"

    static func category(for conversation: RoomConversation) -> String {
        conversation.rawValue + "-message"
    }

    static func reaction(_ emoji: String) -> String {
        "react:" + emoji
    }

    /// The emoji a reaction's action sends, or nil for any other action.
    static func emoji(of action: String) -> String? {
        reactions.first { reaction($0) == action }
    }

    /// What the person calls a conversation: the family room's name, or their assistant's.
    static func name(of conversation: RoomConversation, assistantName: String) -> String {
        conversation == .family ? familyName : assistantName
    }
}
