// What the person did with a notification, for the app to answer: a tap opens its
// conversation, a reply answers the message it showed, and a reaction lands on it.

import Foundation

enum NotificationAnswer: Equatable, Sendable {
    case open(RoomConversation)
    /// The words, and the message they answer when the notification said which.
    case reply(String, to: String?, in: RoomConversation)
    case react(String, to: String, in: RoomConversation)

    /// `conversation` and `messageId` are what the extension left in the notification, or
    /// its thread alone when the extension could not open it. Nil for a notification of no
    /// conversation of this app, and for a reply left empty.
    init?(action: String, typed: String?, conversation: String?, messageId: String?) {
        guard let conversation = conversation.flatMap(RoomConversation.init(rawValue:)) else {
            return nil
        }
        if action == NotificationActions.reply {
            let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            self = .reply(text, to: messageId, in: conversation)
        } else if let emoji = NotificationActions.emoji(of: action), let messageId {
            self = .react(emoji, to: messageId, in: conversation)
        } else {
            self = .open(conversation)
        }
    }
}
