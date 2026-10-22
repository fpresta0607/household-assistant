// The faces a notification shows, drawn by the app into the App Group, because the
// notification extension runs in its own process with no link to the gateway: each
// participant's chosen photo, or their initial or emoji the way the room draws them when
// there is none, beside who is who (NotificationPeople).

import SwiftUI
import UIKit

@MainActor
enum NotificationFaces {
    /// Points across, drawn at three pixels each. A face in a notification is at most a
    /// few dozen points.
    private static let side: CGFloat = 96

    /// Draws each participant's face and writes it with who is who. A face that cannot be
    /// read or written is left out, and the extension shows that person by name alone.
    static func save(_ participants: [RoomParticipant], me: RoomSelf, media: RoomMediaCache) async {
        guard let folder = NotificationFolder.url else {
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for participant in participants {
            guard let file = NotificationPeople.faceFile(for: participant.id) else {
                continue
            }
            let chosen = await photo(of: participant, media: media)
            try? face(of: participant, photo: chosen)?.pngData()?.write(to: folder.appendingPathComponent(file), options: .atomic)
        }
        let people = NotificationPeople(
            me: me.person,
            assistant: me.assistant,
            names: Dictionary(participants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
        try? JSONEncoder().encode(people).write(to: folder.appendingPathComponent(NotificationPeople.file), options: .atomic)
    }

    /// Everything a pairing left there, once it is forgotten.
    static func forget() {
        guard let folder = NotificationFolder.url else {
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// One face as a notification shows it, before iOS cuts it to a circle.
    static func face(of participant: RoomParticipant, photo: UIImage?) -> UIImage? {
        let renderer = ImageRenderer(content: ZStack {
            FaceTile(participant: participant, size: side)
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped())
        renderer.scale = 3
        return renderer.uiImage
    }

    private static func photo(of participant: RoomParticipant, media: RoomMediaCache) async -> UIImage? {
        guard let avatar = participant.avatar, let file = try? await media.url(for: avatar) else {
            return nil
        }
        return await MediaThumbnails.image(for: file, isVideo: false, pixels: side * 3)
    }
}
