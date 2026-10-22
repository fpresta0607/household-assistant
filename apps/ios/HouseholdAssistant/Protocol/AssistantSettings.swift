// What `household-app.settings` answers, and `household-app.settings.change` answers
// again after a write: this phone's own assistant as its gateway holds it, read back from
// the gateway's config, so the phone only ever shows what the gateway really has.
//
// Never a key or a token: a voice by name, a model by name, and each connector on or off,
// with the accounts this phone's own person linked to it and nobody else's.

import Foundation

struct AssistantSettings: Decodable, Equatable, Sendable {
    /// Who the assistant is and how it talks.
    struct Assistant: Decodable, Equatable, Sendable {
        let name: String
        /// An id from `voices`.
        let voice: String
        /// 0 is calm, 100 is lively.
        let tone: Int
        let length: AnswerLength
    }

    let assistant: Assistant
    let voices: [AssistantVoice]
    let model: AssistantModel
    /// Omitted by older gateways. Separate from image generation.
    var visionModel: ModelChoice? = nil
    /// The models its pictures and its videos are made with. A gateway older than them
    /// sends neither, and one with no video model to use sends none for video.
    let imageModel: ModelChoice?
    let videoModel: ModelChoice?
    let connectors: [Connector]
    /// This phone's own choices, by conversation id. Nobody else's are ever here.
    let notifications: [String: NotificationChoice]

    /// A conversation this phone never chose for is `all`.
    func notificationChoice(in conversation: RoomConversation) -> NotificationChoice {
        notifications[conversation.rawValue] ?? .all
    }
}

