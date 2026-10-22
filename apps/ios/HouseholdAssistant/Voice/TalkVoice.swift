// A call's voice: each sentence of the reply spoken by this phone's own gateway in the
// assistant's own voice, ElevenLabs through the gateway's speech provider, so no key is
// ever on the phone. The sentences play here in order, the next one fetched while the one
// before it plays. The rules for that are SpeakQueue's, and this does what it says. There
// is no system voice to fall back on: when the gateway's ceiling for the day is reached
// the call shows the words instead.
//
// The voice plays on the call's own audio engine, the one the microphone runs on
// (SpeechListener wires it in), through a player node: voice processing's echo
// cancellation takes out what plays there, so the microphone stays on while the
// assistant talks and the person can talk over it. The player takes each file as it is
// and converts its rate to the engine's. A holding line from the phone's own copy plays
// the same way, before anything said after it.
//
// Each sentence's audio is read exactly as a voice note is: through the room's media
// cache, which names the file for its type. The gateway speaks for the household channel,
// as it does the voice replies the app plays as voice notes, and that is mp3. The orb
// moves with the voice's real level, read from what the player plays.

import AVFoundation

@MainActor
final class TalkVoice {
    /// A sentence, or a holding line, was said to its end. One that is stopped is not.
    var onSentence: (() -> Void)?
    /// The gateway refused: today's voice is used up.
    var onUsedUp: (() -> Void)?
    /// Anything else went wrong, as a sentence to show.
    var onFailure: ((String) -> Void)?

    /// 0...1, how loud the voice is now.
    private(set) var level: Double = 0

    /// What is on the player and not yet played to its end.
    private enum Played {
        case sentence(Int)
        case holdingLine
    }

    /// One channel, as the voice is. The engine's mixer takes it to the speaker.
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)

    private let player = AVAudioPlayerNode()
    private let connection: GatewayConnection
    private let media: RoomMediaCache
    private var queue = SpeakQueue()
    private var fetching: [Int: Task<Void, Never>] = [:]
    /// Each sentence's audio, opened and ready to play the moment its turn comes.
    private var ready: [Int: AVAudioFile] = [:]
    /// What is scheduled on the player, by the number it was scheduled under. A number is
    /// never used twice, so the end of something stopped is never taken for something new.
    private var scheduled: [Int: Played] = [:]
    private var nextScheduled = 0

    init(connection: GatewayConnection, media: RoomMediaCache) {
        self.connection = connection
        self.media = media
    }

    /// Puts the voice on `engine`, the call's own, once, before it starts and after its
    /// voice processing is on.
    func play(through engine: AVAudioEngine) {
        guard player.engine == nil else {
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let level = SpeechListener.level(of: buffer)
            Task { @MainActor in
                self?.level = level
            }
        }
    }

    /// Queues `sentences` after whatever is still being said.
    func say(_ sentences: [String]) {
        perform(queue.add(sentences))
    }

    /// Says a holding line from the phone's own copy, now, before anything said after it.
    /// One that cannot be read is skipped as if it had been said.
    func hold(_ file: URL) {
        do {
            let audio = try AVAudioFile(forReading: file)
            schedule(audio, as: .holdingLine)
        } catch {
            onSentence?()
        }
    }

    /// The engine started again after the sound moved, to AirPods, the car or the speaker:
    /// whatever was playing plays on.
    func carryOn() {
        if !scheduled.isEmpty, player.engine != nil {
            player.play()
        }
    }

    /// Stops at once and forgets every sentence still queued or on its way.
    func stop() {
        queue.stop()
        for task in fetching.values {
            task.cancel()
        }
        fetching = [:]
        ready = [:]
        scheduled = [:]
        if player.engine != nil {
            player.stop()
        }
        level = 0
    }

    private func perform(_ effects: [SpeakQueue.Effect]) {
        for effect in effects {
            switch effect {
            case .fetch(let id, let text):
                fetch(id, text)
            case .play(let id):
                if let audio = ready.removeValue(forKey: id) {
                    schedule(audio, as: .sentence(id))
                }
            }
        }
    }

    private func fetch(_ id: Int, _ text: String) {
        fetching[id] = Task {
            do {
                let spoken = try await connection.speak(text, voice: nil)
                let file = try await media.url(for: spoken)
                let audio = try AVAudioFile(forReading: file)
                guard !Task.isCancelled else {
                    return
                }
                fetching[id] = nil
                ready[id] = audio
                perform(queue.arrived(id))
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                stop()
                if SpeakQueue.isUsedUp(error) {
                    onUsedUp?()
                } else {
                    onFailure?(ErrorText.describe(error))
                }
            }
        }
    }

    /// Plays `audio` after whatever the player still has. A call on hold says nothing
    /// (TalkSession), so the engine is stopped here only when the call's sound went without
    /// iOS saying so, and a player on a stopped engine cannot play: that ends the voice and
    /// says so.
    private func schedule(_ audio: AVAudioFile, as played: Played) {
        guard let engine = player.engine, engine.isRunning else {
            stop()
            onFailure?("The call's sound stopped. Tap to try again.")
            return
        }
        let number = nextScheduled
        nextScheduled += 1
        scheduled[number] = played
        player.scheduleFile(audio, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.finished(number)
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func finished(_ number: Int) {
        guard let played = scheduled.removeValue(forKey: number) else {
            return
        }
        // The next sentence starts before anyone hears about this one ending.
        if case .sentence(let id) = played {
            perform(queue.finished(id))
        }
        onSentence?()
    }
}
