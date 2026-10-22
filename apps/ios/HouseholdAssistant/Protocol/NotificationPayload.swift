// What a notification says once this phone opens it. The gateway seals it under this
// phone's key (deploy/openclaw/plugins/household-app/push.js), so Apple carries only
// "New message", and the notification extension opens it with PushKey and shows it as a
// message from whoever wrote it.
//
// The conversation and the message ride on in the notification's userInfo, so the app
// knows where a reply or a reaction sent from it goes.

import Foundation

struct NotificationPayload: Decodable, Equatable, Sendable {
    let conversation: RoomConversation
    let messageId: String
    /// Who wrote it, a participant id: how the extension finds their face.
    let sender: String
    /// Their name.
    let title: String
    /// The words, or what was sent when there are none, such as "Photo" or "Voice note".
    let body: String

    static let conversationKey = "conversation"
    static let messageIdKey = "messageId"

    var userInfo: [String: String] {
        [Self.conversationKey: conversation.rawValue, Self.messageIdKey: messageId]
    }

    /// The family room shows as a group, under its name. This phone's own thread is one to one.
    var groupName: String? {
        conversation == .family ? NotificationActions.familyName : nil
    }
}
