// Each voice note's bars, drawn from its own audio once the file is on the phone.
//
// Until then a note shows the bars it carries, which the sender's recorder kept. The file
// is read off the main actor, once per note, and what it gives is kept for the rest of
// the run, so a note scrolled past again draws at once. A file AVFoundation cannot read,
// such as a Telegram voice note in Ogg, keeps the carried bars.

import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceNoteBars {
    static let shared = VoiceNoteBars()

    private var drawn: [String: [Double]] = [:]
    @ObservationIgnored private var started: Set<String> = []

    /// The bars to draw for `media` now. Asking with its file starts the reading, and the
    /// bubble follows when it is done, because it read `drawn` to ask.
    func levels(for media: RoomMedia, at file: URL?) -> [Double] {
        if let bars = drawn[media.id] {
            return bars
        }
        if let file, !started.contains(media.id) {
            started.insert(media.id)
            Task {
                if let bars = await Self.read(file) {
                    drawn[media.id] = bars
                }
            }
        }
        return media.waveform ?? Waveform.bars(from: [])
    }

    /// Nonisolated and async, so the decoding runs on the shared pool, not the main actor.
    nonisolated private static func read(_ file: URL) async -> [Double]? {
        guard
            let audio = try? AVAudioFile(forReading: file),
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
            (try? audio.read(into: buffer)) != nil,
            let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }
        // The first channel: a voice note is mono, and any other channel says the same.
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return Waveform.bars(fromSamples: samples)
    }
}
