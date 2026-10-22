// Each voice note's words, shown under it. Apple's on-device recognition hears the note
// once its file is on this phone, and the words are kept beside the media cache, so a
// note is only ever heard once. Nothing leaves the phone.
//
// Notes are heard one at a time, in the order they first show. Without speech
// permission, or in a language this phone cannot hear on device, a note has no words,
// and nothing here ever asks for permission: the first run's voice step does that.

import Foundation
import Observation
import Speech

@MainActor
@Observable
final class VoiceNoteTranscripts {
    static let shared = VoiceNoteTranscripts()

    private var heard: [String: String] = [:]
    @ObservationIgnored private var started: Set<String> = []
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("voice-note-words", isDirectory: true)

    /// The words of `media`, nil until they are heard or when there are none. Asking with
    /// its file starts the hearing, and the bubble follows when it is done.
    func words(for media: RoomMedia, at file: URL?) -> String? {
        if let words = heard[media.id] {
            return words.isEmpty ? nil : words
        }
        guard let file, !started.contains(media.id), SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return nil
        }
        started.insert(media.id)
        // A media id is the hash of the note's bytes, so it is a safe file name.
        let kept = directory.appendingPathComponent(media.id)
        let previous = queue
        queue = Task {
            if let words = try? String(contentsOf: kept, encoding: .utf8) {
                heard[media.id] = words
                return
            }
            await previous?.value
            let words = await Self.hear(file) ?? ""
            heard[media.id] = words
            // Kept only when something was heard, so a failed hearing is tried again next run.
            if !words.isEmpty {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? words.write(to: kept, atomically: true, encoding: .utf8)
            }
        }
        return nil
    }

    /// Every note's words heard so far, by media id, for a search (ThreadSearch).
    var known: [String: String] {
        heard.filter { !$0.value.isEmpty }
    }

    /// For the demo and the screenshots, which have no recognizer to hear with.
    func remember(_ words: String, for id: String) {
        heard[id] = words
    }

    nonisolated private static func hear(_ file: URL) async -> String? {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let answer = Answer()
        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    answer.give(result.bestTranscription.formattedString, to: continuation)
                } else if error != nil {
                    answer.give(nil, to: continuation)
                }
            }
        }
    }

    /// The recognizer may call back after it has answered once; only the first answer counts.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var isGiven = false

        func give(_ words: String?, to continuation: CheckedContinuation<String?, Never>) {
            lock.lock()
            defer {
                lock.unlock()
            }
            guard !isGiven else {
                return
            }
            isGiven = true
            continuation.resume(returning: words)
        }
    }
}
