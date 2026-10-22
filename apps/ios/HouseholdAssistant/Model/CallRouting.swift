// Where a call's sound goes: the speaker, the earpiece, or AirPods, a headset or the car.
//
// A call starts on the speaker, the way a voice assistant is talked to, on the phone held
// out or in the car. The Speaker button flips the person's choice between the speaker and
// the earpiece. On the speaker, raising the phone to the ear moves the sound to the
// earpiece by itself, and lowering it moves it back; chosen with the button, the earpiece
// stays when the phone is lowered. Whatever is connected, AirPods, a headset or the car,
// takes the sound for as long as it is, and the ear only matters between the speaker and
// the earpiece, so the proximity sensor is watched only while nothing is connected. The
// screen goes dark at the ear while it is watched.
//
// The person's choice, the ear and what is connected in, the output and the button's look
// out (CallAudio applies it). Pure, so every combination is a plain test.

import Foundation

struct CallRouting: Equatable, Sendable {
    enum Output: Equatable, Sendable {
        case speaker
        case earpiece
        /// AirPods, a headset or the car, wherever iOS sends a call while one is connected.
        case external
    }

    /// Whether the person chose the earpiece with the Speaker button. The speaker until
    /// they do.
    var isEarpieceChosen = false
    /// Whether the phone is at the ear, by the proximity sensor.
    var isNearEar = false
    /// AirPods, a headset or the car while one is connected.
    var device: CallAudioRoutes.Device?

    var output: Output {
        if device != nil {
            return .external
        }
        return isEarpieceChosen || isNearEar ? .earpiece : .speaker
    }

    /// Whether the proximity sensor is watched, which turns the screen off at the ear: only
    /// while the sound is the phone's own.
    var isProximityWatched: Bool {
        device == nil
    }

    /// Whether the button flips between the speaker and the earpiece. While something is
    /// connected it only shows what has the sound.
    var canToggle: Bool {
        device == nil
    }

    /// Lit, as an iPhone call lights it, on the speaker or on what is connected.
    var isButtonLit: Bool {
        device != nil || !isEarpieceChosen
    }

    /// Speaker, or Audio while something connected has the sound.
    var buttonTitle: String {
        device == nil ? "Speaker" : "Audio"
    }

    var buttonSymbol: String {
        device?.symbol ?? "speaker.wave.2.fill"
    }
}
