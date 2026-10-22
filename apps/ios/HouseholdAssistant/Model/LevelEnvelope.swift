// Smooths a raw audio level into something an Orb can wear.
//
// Fast attack, slow release, so a syllable makes the Orb swell at once and
// settle gently. The same envelope serves both directions: the microphone's
// measured level while listening, and the voice's level, read from its
// player, while speaking.

import Foundation

struct LevelEnvelope: Equatable, Sendable {
    private(set) var level: Double = 0

    // Tuning knobs. Real microphones and rooms differ; these are the values to
    // turn on the first device run, not constants of nature.
    var attack: Double = 0.6
    var release: Double = 0.12

    /// Feeds one measurement in 0...1 and returns the smoothed level.
    mutating func feed(_ target: Double) -> Double {
        let clamped = min(max(target, 0), 1)
        let rate = clamped > level ? attack : release
        level += (clamped - level) * rate
        return level
    }

    /// Maps the RMS of a buffer of samples to 0...1 on a decibel scale.
    static func normalized(rms: Double, floorDecibels: Double = -50) -> Double {
        guard rms > 0 else {
            return 0
        }
        let decibels = 20 * log10(rms)
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }
}
