// A voice's bars beside its name: drawn from the sample's own audio once it has been
// spoken, filling as it plays, and a quiet resting shape until then.

import SwiftUI

struct VoiceSampleBars: View {
    let voice: String
    let words: String

    @Environment(AppModel.self) private var model
    @State private var player = VoiceNotePlayer.shared

    /// Before the sample is spoken there is no audio to draw from.
    private static let resting = [0.35, 0.7, 1, 0.55, 0.85, 0.3, 0.6, 0.45]

    var body: some View {
        let sample = model.assistantSettings.spokenSample(words, voice: voice)
        let isPlaying = sample.map { player.current == $0.id && player.isPlaying } ?? false
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { _ in
            WaveformBars(
                levels: levels(of: sample),
                progress: sample.map { player.progress(of: $0.id) } ?? 0,
                played: Palette.highlight,
                unplayed: Palette.highlight.opacity(0.35)
            )
        }
        .frame(width: 54, height: 20)
        .accessibilityHidden(true)
    }

    private func levels(of sample: RoomMedia?) -> [Double] {
        guard let sample else {
            return Self.resting
        }
        // A spoken sample is many bars; the row has room for a few.
        let bars = VoiceNoteBars.shared.levels(for: sample, at: model.media.cachedURL(for: sample))
        return Waveform.bars(from: bars, count: Self.resting.count)
    }
}
