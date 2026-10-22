// A message's photos, videos, voice notes and files as files to share from its menu,
// read from the gateway or this phone, under the names a person would give them
// ("Photo.jpg", the file's own name) rather than the hash the cache keeps them under.
// Each is linked to its cached copy, so sharing a video does not copy it.

import Foundation

@MainActor
enum MessageFiles {
    /// Nil when any of them could not be read, so a share never leaves one out unsaid.
    static func files(of message: RoomMessage, from media: RoomMediaCache) async -> [URL]? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent(message.id, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        var taken: Set<String> = []
        var files: [URL] = []
        for item in message.media {
            guard let cached = try? await media.url(for: item) else {
                return nil
            }
            let name = PlainFileName.unique(item.fileName, taken: taken)
            taken.insert(name)
            // The cache and the temporary folder are both in the app's own container.
            let file = folder.appendingPathComponent(name)
            guard (try? FileManager.default.linkItem(at: cached, to: file)) != nil else {
                return nil
            }
            files.append(file)
        }
        return files
    }
}
