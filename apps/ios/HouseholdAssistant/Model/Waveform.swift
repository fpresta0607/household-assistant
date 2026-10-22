// The bars a voice note is drawn with. While it records, the recorder's levels are
// averaged into a fixed number of bars that travel with the note, so every phone can
// draw it before it has the audio. Once the note's file is on the phone, the bars are
// drawn again from its own samples, on the same scale.

import Foundation

enum Waveform {
    /// The bars every voice note carries.
    static let barCount = 48
    /// The shortest bar, so silence still reads as a voice note.
    static let floor = 0.05
    /// The quietest level that still moves a bar, in decibels from full scale.
    static let quietest: Double = -50

    /// `levels`, 0...1, averaged into `count` bars of equal share.
    static func bars(from levels: [Double], count: Int = barCount) -> [Double] {
        guard count > 0 else {
            return []
        }
        guard !levels.isEmpty else {
            return Array(repeating: floor, count: count)
        }
        return shares(of: levels.count, count: count).map { share in
            let mean = levels[share].reduce(0, +) / Double(share.count)
            return max(mean, floor)
        }
    }

    /// PCM samples, -1...1, as `count` bars: each bar how loud its share of the samples
    /// is, in decibels the way the recorder's meter reads them, so a note drawn from its
    /// own audio looks like the one drawn while it was recorded.
    static func bars(fromSamples samples: [Float], count: Int = barCount) -> [Double] {
        guard count > 0 else {
            return []
        }
        guard !samples.isEmpty else {
            return Array(repeating: floor, count: count)
        }
        return shares(of: samples.count, count: count).map { share in
            var power = 0.0
            for sample in samples[share] {
                power += Double(sample) * Double(sample)
            }
            let loudness = (power / Double(share.count)).squareRoot()
            // Silence is minus infinity decibels, which the level clamps to nothing.
            return max(level(decibels: 20 * log10(loudness)), floor)
        }
    }

    /// A meter's average power, in decibels, as a level from 0 to 1.
    static func level(decibels: Double) -> Double {
        min(max((decibels - quietest) / -quietest, 0), 1)
    }

    /// `total` items split into `count` runs of equal share, each at least one long, so
    /// fewer items than bars still fill every bar.
    private static func shares(of total: Int, count: Int) -> [Range<Int>] {
        (0..<count).map { bar in
            let start = bar * total / count
            let end = max((bar + 1) * total / count, start + 1)
            return min(start, total - 1)..<min(end, total)
        }
    }
}
