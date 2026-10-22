// One thing a phone can change about its own assistant, spelled as
// deploy/openclaw/plugins/household-app spells it in `household-app.settings.change`.

import Foundation

enum SettingsField: Hashable, Sendable {
    case name
    case voice
    case tone
    case length
    case model
    /// The model that reads photos, screenshots and charts.
    case visionModel
    /// The second (1) or third (2) model of the chain, used in that order when the one
    /// before fails: an OpenRouter id like `model`, or empty for none.
    case fallbackModel(Int)
    /// The models its pictures and its videos are made with, each an OpenRouter id like `model`.
    case imageModel
    case videoModel
    /// A connector, by its id from `connectors`: `on` or `off`.
    case connector(String)
    /// This phone's own choice for one conversation, which changes nothing for anyone else.
    case notifications(RoomConversation)

    var key: String {
        switch self {
        case .name:
            return "name"
        case .voice:
            return "voice"
        case .tone:
            return "tone"
        case .length:
            return "length"
        case .model:
            return "model"
        case .visionModel:
            return "model.vision"
        case .fallbackModel(let position):
            return "model.fallback.\(position)"
        case .imageModel:
            return "model.image"
        case .videoModel:
            return "model.video"
        case .connector(let id):
            return "connector.\(id)"
        case .notifications(let conversation):
            return "notifications.\(conversation.rawValue)"
        }
    }
}

