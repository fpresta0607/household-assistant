import Foundation
import Observation

/// Playback belongs to an explicit message action, never an incoming chat reply.
/// Only the current chunk and one ahead are generated, and cancelled results cannot play.
@MainActor
@Observable
final class MessageSpeechPlayer {
    private(set) var messageID: String?
    private(set) var voiceName = ""
    private(set) var isLoading = false
    private(set) var failure: String?

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let media: RoomMediaCache
    @ObservationIgnored private var queue = SpeakQueue()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var voice: String?
    @ObservationIgnored private var fetching: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var ready: [Int: URL] = [:]

    init(connection: GatewayConnection, media: RoomMediaCache) {
        self.connection = connection
        self.media = media
    }

    func speak(messageID: String, text: String, voice: String?, name: String) {
        stop()
        failure = nil
        let chunks = MessageSpeechText.chunks(text)
        guard !chunks.isEmpty else { return }
        VoiceNotePlayer.shared.stop()
        self.messageID = messageID
        self.voice = voice
        voiceName = name
        isLoading = true
        reservePlayback()
        perform(queue.add(chunks))
    }

    func stop() {
        let playbackPrefix = "message-speech:\(generation):"
        generation = UUID()
        messageID = nil
        isLoading = false
        queue.stop()
        fetching.values.forEach { $0.cancel() }
        fetching = [:]
        ready = [:]
        if VoiceNotePlayer.shared.current?.hasPrefix(playbackPrefix) == true {
            VoiceNotePlayer.shared.stop()
        }
    }

    func clearFailure() { failure = nil }

    private func perform(_ effects: [SpeakQueue.Effect]) {
        for effect in effects {
            guard messageID != nil else { return }
            switch effect {
            case .fetch(let id, let text): fetch(id, text: text)
            case .play(let id): play(id)
            }
        }
    }

    private func fetch(_ id: Int, text: String) {
        let generation = self.generation
        let voice = self.voice
        fetching[id] = Task {
            do {
                let spoken = try await connection.speak(text, voice: voice)
                try Task.checkCancellation()
                let file = try await media.url(for: spoken)
                guard !Task.isCancelled, generation == self.generation else { return }
                fetching[id] = nil
                ready[id] = file
                perform(queue.arrived(id))
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                stop()
                failure = ErrorText.describe(error)
            }
        }
    }

    private func play(_ id: Int) {
        guard let url = ready.removeValue(forKey: id) else { return }
        let generation = self.generation
        let started = VoiceNotePlayer.shared.play("message-speech:\(generation):\(id)", at: url,
            continuing: "message-speech:\(generation):",
            onFinished: { [weak self] in
                guard let self, self.generation == generation else { return }
                let effects = self.queue.finished(id)
                if self.queue.isEmpty {
                    self.stop()
                } else {
                    self.isLoading = true
                    self.reservePlayback()
                    self.perform(effects)
                }
            }, onStopped: { [weak self] in
                guard let self, self.generation == generation else { return }
                self.stop()
            })
        if started {
            isLoading = false
        } else {
            stop()
            failure = "The message couldn't be played. End any active call and try again."
        }
    }

    private func reservePlayback() {
        let generation = self.generation
        VoiceNotePlayer.shared.reserve("message-speech:\(generation):") { [weak self] in
            guard let self, self.generation == generation else { return }
            self.stop()
        }
    }
}
