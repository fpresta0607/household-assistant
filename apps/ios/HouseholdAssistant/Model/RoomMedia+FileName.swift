// What an attachment is called as a file of its own, shared out of a conversation: a
// file by the name it was sent with, anything else by what it is, with the extension its
// type takes. Never the hash the gateway keeps it under.

import Foundation

extension RoomMedia {
    var fileName: String {
        if let name, !name.isEmpty {
            return name
        }
        let stem: String
        switch kind {
        case .photo:
            stem = "Photo"
        case .video:
            stem = "Video"
        case .voice:
            stem = "Voice note"
        case .file:
            stem = "File"
        }
        return stem + "." + RoomMediaCache.fileExtension(for: mime)
    }
}
