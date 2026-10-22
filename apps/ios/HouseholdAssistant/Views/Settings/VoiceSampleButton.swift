// Plays a voice: the words are spoken by this phone's own gateway in that voice, the
// first time they are asked for, and played like a voice note at its own speed. The other
// assistant's voice plays the same way, through this phone's own gateway.

import SwiftUI

struct VoiceSampleButton: View {
    let voice: String
    let words: String
    let voiceName: String

    @Environment(AppModel.self) private var model
    @State private var player = VoiceNotePlayer.shared
    @State private var isFetching = false

    var body: some View {
        let sample = model.assistantSettings.spokenSample(words, voice: voice)
        let isPlaying = sample.map { player.current == $0.id && player.isPlaying } ?? false
        Button {
            play()
        } label: {
            ZStack {
                Circle()
                    .fill(Palette.highlight)
                if isFetching {
                    ProgressView()
                        .tint(Palette.onAccent)
                        .controlSize(.small)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(isFetching)
        .accessibilityLabel(isPlaying ? "Pause \(voiceName)'s voice" : "Play \(voiceName)'s voice")
    }

    private func play() {
        isFetching = true
        Task {
            defer {
                isFetching = false
            }
            guard
                let sample = await model.assistantSettings.sample(words, voice: voice),
                let file = try? await model.media.url(for: sample)
            else {
                return
            }
            player.toggle(sample.id, at: file, fixedSpeed: .normal)
        }
    }
}
