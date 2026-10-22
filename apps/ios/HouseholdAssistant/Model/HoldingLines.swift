// The holding lines a call says while the assistant thinks ("One sec."), in the assistant's
// own voice: each spoken once by its gateway and kept on this phone, so a line is ready the
// moment a wait needs it and costs Talk's daily ceiling nothing after the first time.
// They are kept for the voice they were spoken in, so a voice changed in Settings speaks
// them afresh.
//
// The record of which audio is which line sits beside the room's media in the system's
// caches: when the system empties those, both go together and each line is spoken again
// once. A record that cannot be read or written only means speaking a line again.

import Foundation

@MainActor
final class HoldingLines {
    private let connection: GatewayConnection
    private let media: RoomMediaCache
    private let record: URL
    /// Each line's audio as its gateway spoke it, by voice, then by line.
    private var spoken: [String: [String: RoomMedia]]
    /// Each line's audio file in this call's voice, once it is on this phone.
    private var files: [String: URL] = [:]

    init(connection: GatewayConnection, media: RoomMediaCache, record: URL) {
        self.connection = connection
        self.media = media
        self.record = record
        spoken = (try? JSONDecoder().decode([String: [String: RoomMedia]].self, from: Data(contentsOf: record))) ?? [:]
    }

    /// Where the record is kept on the phone, beside the room's media.
    static func standardRecord() -> URL {
        RoomMediaCache.standardDirectory().appendingPathComponent("holding-lines.json")
    }

    /// Readies `lines` in the voice the assistant speaks in now, asking its gateway to speak
    /// only those it never has in that voice. A line that cannot be readied stops the
    /// readying, a refusal for today's ceiling included, and its record is forgotten so a
    /// later call speaks it afresh: the call carries on without it, and the assistant's own
    /// line before anything slow still covers the wait. A call that ends stops the readying,
    /// so a call tried again at once does not have every line spoken twice.
    func prepare(_ lines: [String]) async {
        guard !Task.isCancelled, let voice = try? await connection.assistantSettings().assistant.voice else {
            return
        }
        for line in lines {
            guard !Task.isCancelled else {
                return
            }
            do {
                let audio: RoomMedia
                if let kept = spoken[voice]?[line] {
                    audio = kept
                } else {
                    audio = try await connection.speak(line, voice: nil)
                    spoken[voice, default: [:]][line] = audio
                    save()
                }
                files[line] = try await media.url(for: audio)
            } catch {
                if spoken[voice]?.removeValue(forKey: line) != nil {
                    save()
                }
                return
            }
        }
    }

    /// The line's audio on this phone, or nil while it is not ready.
    func file(for line: String) -> URL? {
        files[line]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(spoken).write(to: record, options: .atomic)
    }
}
