// Microphone in, words out, on this phone only.
//
// `SFSpeechRecognizer` with `requiresOnDeviceRecognition`: audio never leaves
// the device, and a language the phone cannot recognise locally is reported
// as such rather than quietly sent to a server. The same microphone tap that
// feeds the recogniser measures the level the orb moves to.
//
// The microphone runs through Apple's voice processing, for its noise
// suppression and its echo cancellation, on sound set up for voice chat by
// whoever runs it: for a call the call itself, whose sound iOS hands over
// through CallKit (SystemCall). That cancellation
// takes out whatever plays through this same engine, so a call hands in its
// voice (TalkVoice) to play here: the microphone stays on while the assistant
// talks, and hears the person talking over it rather than the phone hearing
// itself. Voice processing also ducks every other sound, so that ducking is
// kept to its least.
//
// In a call the engine runs until the call ends or goes on hold. Each turn
// starts a fresh recognition on the running engine, so the voice is never cut
// by it. A recognition that ends on its own, after a long silence or about a
// minute, is followed by the next one, whose words come after what it heard, so
// a turn is never cut in two. Muted, nothing is heard at all: voice processing
// mutes the microphone's input, and no sound reaches the recogniser or the
// level.
//
// iOS stops the engine whenever the sound moves, to AirPods, the car, the
// speaker or back, because the formats move with it. It starts again on the
// new route at once, its words carried into a new recognition and the voice
// playing on, so a route change never drops the call.
//
// The microphone is tapped only when iOS says it has input, which Apple says to
// check before any input: input from a microphone with none can raise an
// exception nothing catches. Nor is it tapped while the engine is stopped as the
// sound moves, since the old route's formats may still be set until the engine
// starts again on the new one. A recognition opens only when the microphone can
// be tapped, so none waits with nothing to hear, and the engine's next start
// opens one. Starting, or starting again on a new route, without input says so,
// and a tap tries again. The microphone is not touched before the first start
// either, so it is first set up on sound that can record.

import AVFoundation
import Speech

@MainActor
final class SpeechListener {
    var onTranscript: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Whether the microphone is muted. The engine, and any voice playing through it, runs
    /// on.
    var isMuted = false {
        didSet {
            guard isMuted != oldValue, isRunning else {
                return
            }
            applyMute()
        }
    }

    /// Whether the engine is running, from `start()` until `stop()`.
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    /// The call's voice, played through this engine. Nil when nothing plays through it.
    private let voice: TalkVoice?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Counts recognitions, so the words of one already ended are never taken for the next.
    private var recognition = 0
    /// What this recognition has heard so far.
    private var heard = ""
    /// What earlier recognitions of this turn heard, which this one's words come after.
    private var earlier = ""
    private var startedAt = Date()
    /// Watches for the sound moving while the engine runs.
    private var routeChanges: NSObjectProtocol?

    /// A recognition that gives up sooner than this having heard nothing is broken
    /// rather than met with silence.
    private static let shortestSilence: TimeInterval = 2

    init(voice: TalkVoice? = nil) {
        self.voice = voice
    }

    /// Asks for the two permissions. Returns what to tell the person when one is refused.
    static func requestAccess() async -> String? {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            return "Allow Speech Recognition for this app in Settings."
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            return "Allow the microphone for this app in Settings."
        }
        return nil
    }

    /// Starts hearing on the sound as it is set up now, which whoever runs this has taken
    /// first. Running already, it carries on.
    func start() {
        guard !isRunning else {
            return
        }
        guard engine.inputNode.hasInput else {
            onFailure?("The microphone is not available right now. Tap to try again.")
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            onFailure?("On-device speech recognition is not available in this language.")
            return
        }
        do {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
            // After voice processing is on, which sets the formats the voice is played in.
            voice?.play(through: engine)

            input.isVoiceProcessingInputMuted = isMuted
            engine.prepare()
            try engine.start()
            isRunning = true
            earlier = ""
            followRouteChanges()
            beginRecognition()
        } catch {
            engine.stop()
            onFailure?("The microphone could not be started.")
        }
    }

    /// Starts the person's next turn from nothing: what was heard so far is forgotten, and
    /// the microphone, and any voice playing, carry on.
    func beginTurn() {
        guard isRunning else {
            return
        }
        endRecognition()
        earlier = ""
        beginRecognition()
    }

    /// Stops the engine, and any voice playing through it. The sound is left as it is, for
    /// whoever took it to give back. One not running is left alone, its microphone untouched.
    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        if let routeChanges {
            NotificationCenter.default.removeObserver(routeChanges)
            self.routeChanges = nil
        }
        endRecognition()
        engine.stop()
    }

    // MARK: - The sound moving

    private func followRouteChanges() {
        guard routeChanges == nil else {
            return
        }
        routeChanges = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // Asked for on the main queue.
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.restart()
            }
        }
    }

    /// The engine stopped as the sound moved. What this recognition heard carries on in a
    /// new one, since a recognition is not handed a new format midway, and the voice plays
    /// on from where it was.
    private func restart() {
        guard isRunning else {
            return
        }
        let heardSoFar = heard
        endRecognition()
        if !heardSoFar.isEmpty {
            earlier = afterEarlier(heardSoFar)
        }
        guard engine.inputNode.hasInput else {
            stop()
            onFailure?("The microphone is not available right now. Tap to try again.")
            return
        }
        do {
            engine.inputNode.isVoiceProcessingInputMuted = isMuted
            engine.prepare()
            try engine.start()
            beginRecognition()
            voice?.carryOn()
        } catch {
            stop()
            onFailure?("The microphone could not be started.")
        }
    }

    // MARK: - Recognitions

    /// Whether the microphone can be tapped now: it has input, and the engine runs, so its
    /// formats are the route's own.
    private var canTap: Bool {
        engine.isRunning && engine.inputNode.hasInput
    }

    /// Opens a recognition for the microphone to hear into. None while it cannot be tapped:
    /// the engine's next start opens one.
    private func beginRecognition() {
        guard let recognizer, canTap else {
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request
        recognition += 1
        let this = recognition
        startedAt = Date()
        if !isMuted {
            hear(into: request)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isOver = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self, self.isRunning, self.recognition == this else {
                    return
                }
                if let text, !text.isEmpty {
                    self.heard = text
                    self.onTranscript?(self.afterEarlier(text))
                }
                if isOver {
                    self.recognitionEnded(heard: text)
                }
            }
        }
    }

    /// The recognition ended on its own. Its words are kept for the next to follow on from.
    /// While muted the next waits for unmuting, since there is nothing to hear.
    private func recognitionEnded(heard text: String?) {
        if let text, !text.isEmpty {
            earlier = afterEarlier(text)
        }
        let isBroken = heard.isEmpty && !isMuted && Date().timeIntervalSince(startedAt) < Self.shortestSilence
        endRecognition()
        if isBroken {
            stop()
            onFailure?("I could not hear that. Tap to try again.")
        } else if !isMuted {
            beginRecognition()
        }
    }

    private func endRecognition() {
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recognition += 1
        heard = ""
    }

    private func afterEarlier(_ text: String) -> String {
        earlier.isEmpty ? text : earlier + " " + text
    }

    /// Sends what the microphone hears to `request`, and its level to the orb, while it can
    /// be tapped. Otherwise the engine's next start hears again.
    private func hear(into request: SFSpeechAudioBufferRecognitionRequest) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        guard canTap else {
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            request.append(buffer)
            let level = SpeechListener.level(of: buffer)
            Task { @MainActor in
                self?.onLevel?(level)
            }
        }
    }

    /// Mutes or unmutes the running microphone. Unmuted, it hears into the recognition
    /// still open, or a new one when the last ended while muted.
    private func applyMute() {
        let input = engine.inputNode
        input.isVoiceProcessingInputMuted = isMuted
        if isMuted {
            input.removeTap(onBus: 0)
            onLevel?(0)
        } else if let request {
            hear(into: request)
        } else {
            beginRecognition()
        }
    }

    /// The buffer's RMS on a decibel scale, 0...1. Runs on the audio thread.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return 0
        }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        return LevelEnvelope.normalized(rms: Double((sum / Float(buffer.frameLength)).squareRoot()))
    }
}
