// The photos, voice notes, videos and files of the app's conversations, read from the
// gateway in chunks, once each, into a cache on this phone.
//
// A file is kept under its hash with the extension its player expects, and only once
// every byte the message promised has arrived, so a broken read never leaves a file that
// plays wrong. Two screens asking for the same file at once share one read.

import Foundation

@MainActor
final class RoomMediaCache {
    private let connection: GatewayConnection
    private let directory: URL
    private var reading: [String: Task<URL, Error>] = [:]

    init(connection: GatewayConnection, directory: URL) {
        self.connection = connection
        self.directory = directory
    }

    /// The standard place: the app's caches, which the system may empty when space runs low.
    static func standardDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("room-media", isDirectory: true)
    }

    private static func isHash(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The extension a file of `mime` takes. Nothing of the cache's, so any caller may ask.
    nonisolated static func fileExtension(for mime: String) -> String {
        switch mime.lowercased() {
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac":
            return "m4a"
        case "audio/ogg", "audio/opus":
            return "ogg"
        case "audio/mpeg":
            return "mp3"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/heic":
            return "heic"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "application/pdf":
            return "pdf"
        default:
            return "bin"
        }
    }

    private func location(for media: RoomMedia) -> URL {
        directory.appendingPathComponent("\(media.id).\(Self.fileExtension(for: media.mime))")
    }

    /// The file, when every byte of it is already on this phone.
    func cachedURL(for media: RoomMedia) -> URL? {
        guard Self.isHash(media.id) else {
            return nil
        }
        let url = location(for: media)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return size == media.bytes ? url : nil
    }

    func url(for media: RoomMedia) async throws -> URL {
        guard Self.isHash(media.id) else {
            throw GatewayConnectionError.unexpectedFrame
        }
        if let cached = cachedURL(for: media) {
            return cached
        }
        if let running = reading[media.id] {
            return try await running.value
        }
        let task = Task { try await self.read(media) }
        reading[media.id] = task
        defer {
            reading[media.id] = nil
        }
        return try await task.value
    }

    private func read(_ media: RoomMedia) async throws -> URL {
        var bytes = Data()
        var offset = 0
        repeat {
            let chunk = try await connection.roomMedia(id: media.id, offset: offset)
            guard let data = Data(base64Encoded: chunk.data), chunk.total == media.bytes else {
                throw GatewayConnectionError.unexpectedFrame
            }
            bytes.append(data)
            offset += data.count
            guard !data.isEmpty || offset >= chunk.total else {
                throw GatewayConnectionError.unexpectedFrame
            }
        } while offset < media.bytes
        guard bytes.count == media.bytes else {
            throw GatewayConnectionError.unexpectedFrame
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = location(for: media)
        let partial = url.appendingPathExtension("part")
        try bytes.write(to: partial, options: .atomic)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }
}
