// What a model does: answers, image reading, picture creation or video creation. The Model page
// has a segment for each, and `household-app.models` takes it as `kind`.

import Foundation

enum ModelKind: String, CaseIterable, Sendable {
    case text, vision, image, video

    var label: String {
        switch self {
        case .text:
            return "Text"
        case .vision:
            return "Vision"
        case .image:
            return "Image"
        case .video:
            return "Video"
        }
    }

    /// The setting that changes the model of this kind.
    var field: SettingsField {
        switch self {
        case .text:
            return .model
        case .vision:
            return .visionModel
        case .image:
            return .imageModel
        case .video:
            return .videoModel
        }
    }
}

