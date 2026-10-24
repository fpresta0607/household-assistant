// The SF Symbol for each kind of attachment, used wherever one is named without words.

import Foundation

enum RoomMediaSymbol {
    static func name(for kind: RoomMedia.Kind) -> String {
        switch kind {
        case .voice:
            return "waveform"
        case .photo:
            return "photo"
        case .video:
            return "video.fill"
        case .file:
            return "doc.fill"
        }
    }
}
