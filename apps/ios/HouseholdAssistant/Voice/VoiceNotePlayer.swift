// Plays one voice note at a time, the way Telegram does: starting another stops the
// last, the speed chip applies to whatever plays, and the bubble reads how far it got.
// The speed is kept on this phone, and set from the chip or from Notifications in
// Settings. A voice's sample in Settings plays here too, always at its own speed.

import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceNotePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoiceNotePlayer()

    /// The voice note playing or paused, by its media id.
    private(set) var current: String?
    private(set) var isPlaying = false
    var speed = PlaybackSpeed(rawValue: UserDefaults.standard.double(forKey: VoiceNotePlayer.speedKey)) ?? .normal {
        didSet {
            player?.rate = Float(speed.rawValue)
            UserDefaults.standard.set(speed.rawValue, forKey: Self.speedKey)
        }
    }

    nonisolated static let speedKey = "playback-speed"

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var onFinished: (() -> Void)?
    @ObservationIgnored private var onStopped: (() -> Void)?

    /// Reserve playback while a message's next chunk is loading. Another note or a
    /// recording can cancel that reservation before any generated audio arrives.
    func reserve(_ owner: String, onStopped: @escaping () -> Void) {
        stop()
        current = owner
        self.onStopped = onStopped
    }

    /// 0...1 through the note that is current.
    func progress(of id: String) -> Double {
        guard current == id, let player, player.duration > 0 else {
            return 0
        }
        return player.currentTime / player.duration
    }

    /// `fixedSpeed` plays it at that speed whatever the chip says, for a voice's sample.
    func toggle(_ id: String, at url: URL, fixedSpeed: PlaybackSpeed? = nil) {
        if current == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }
        play(id, at: url, fixedSpeed: fixedSpeed)
    }

    /// Message speech uses the same player, so another note or a recording stops it too.
    @discardableResult
    func play(_ id: String, at url: URL, fixedSpeed: PlaybackSpeed? = nil, continuing owner: String? = nil,
              onFinished: (() -> Void)? = nil, onStopped: (() -> Void)? = nil) -> Bool {
        if let owner, current?.hasPrefix(owner) == true { self.onStopped = nil }
        stop()
        do {
            try AudioFocus.take(.playback, mode: .spokenAudio)
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = Float((fixedSpeed ?? speed).rawValue)
            player.delegate = self
            guard player.play() else {
                AudioFocus.giveBack()
                return false
            }
            self.player = player
            self.onFinished = onFinished
            self.onStopped = onStopped
            current = id
            isPlaying = true
            return true
        } catch {
            stop()
            if AudioFocus.isHeld(.playback, mode: .spokenAudio) { AudioFocus.giveBack() }
            return false
        }
    }

    func seek(_ id: String, to fraction: Double) {
        guard current == id, let player else {
            return
        }
        player.currentTime = player.duration * min(max(fraction, 0), 1)
    }

    func stop() {
        let stopped = onStopped
        onStopped = nil
        onFinished = nil
        if let player {
            player.stop()
            AudioFocus.giveBack()
        }
        player = nil
        current = nil
        isPlaying = false
        stopped?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            let finished = flag ? self.onFinished : self.onStopped
            self.onStopped = nil
            self.stop()
            finished?()
        }
    }
}

