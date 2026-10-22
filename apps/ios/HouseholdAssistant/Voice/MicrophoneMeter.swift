// The microphone's level, live, for the first run's microphone step: once access is given,
// its bars move with the room's sound, so the person sees it hears them. Nothing is
// recorded or kept. It takes the sound mixing with whatever plays, so music carries on,
// and gives it back the moment the step goes.

import AVFoundation
import Observation

@MainActor
@Observable
final class MicrophoneMeter {
    static let barCount = 28

    /// The newest levels, 0...1, oldest first, on the same scale as a voice note's bars.
    private(set) var levels = Array(repeating: Waveform.floor, count: barCount)
    /// Whether it has the microphone and is listening.
    private(set) var isHearing = false

    @ObservationIgnored private let engine = AVAudioEngine()

    /// Does nothing until the microphone is allowed.
    func start() {
        guard !isHearing, AVAudioApplication.shared.recordPermission == .granted else {
            return
        }
        do {
            try AudioFocus.take(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            isHearing = true
            let input = engine.inputNode
            // Input from a microphone with none can raise an exception nothing catches.
            guard input.hasInput else {
                stop()
                return
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                let level = MicrophoneMeter.level(of: buffer)
                Task { @MainActor in
                    self?.hear(level)
                }
            }
            engine.prepare()
            try engine.start()
        } catch {
            stop()
        }
    }

    func stop() {
        guard isHearing else {
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        AudioFocus.giveBack()
        isHearing = false
    }

    private func hear(_ level: Double) {
        levels = Array((levels + [level]).suffix(Self.barCount))
    }

    /// One buffer's loudness as a bar. Runs on the audio thread.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return Waveform.floor
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return Waveform.bars(fromSamples: samples, count: 1)[0]
    }
}
