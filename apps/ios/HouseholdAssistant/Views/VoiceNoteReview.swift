// Listening back to a stopped note before it goes, as Telegram's preview does: the bin,
// play and pause, the note's own bars to scrub through with a finger, and how long it is,
// or how far it has played. Send is the composer's own button beside it. It plays
// through the one voice note player, so it stops whatever note was playing in the thread.

import SwiftUI

struct VoiceNoteReview: View {
    let file: URL
    /// The note's bars, the ones it will carry.
    let levels: [Double]
    let durationMs: Int
    let onDiscard: () -> Void

    @State private var player = VoiceNotePlayer.shared

    /// The player's id for a note kept at `file`, so the composer can stop it.
    static func playerId(for file: URL) -> String {
        "listen-back:" + file.lastPathComponent
    }

    private var id: String {
        Self.playerId(for: file)
    }

    var body: some View {
        let isCurrent = player.current == id
        let isPlaying = isCurrent && player.isPlaying
        HStack(spacing: 12) {
            Button("Delete voice note", systemImage: "trash.fill", action: onDiscard)
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .font(.title3)
            Button {
                player.toggle(id, at: file)
            } label: {
                // A royal glyph in a royal ring, never a royal fill.
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.highlight)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle()
                            .strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1.5)
                    }
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Listen back")
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { _ in
                let progress = player.progress(of: id)
                HStack(spacing: 12) {
                    scrubber(progress: progress)
                    Text(VoiceNoteGesture.clock(milliseconds: isCurrent ? Int(progress * Double(durationMs)) : durationMs))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Palette.text)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 56)
        .liquidGlass(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your voice note, \(VoiceNoteGesture.clock(milliseconds: durationMs)), not sent yet")
    }

    /// The bars, played up to `progress`. A finger on them plays from where it is.
    private func scrubber(progress: Double) -> some View {
        GeometryReader { geometry in
            WaveformBars(levels: levels, progress: progress, played: Palette.highlight, unplayed: Palette.text.opacity(0.3))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            scrub(to: drag.location.x / max(geometry.size.width, 1))
                        }
                )
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }

    private func scrub(to fraction: Double) {
        if player.current != id {
            player.toggle(id, at: file)
        }
        player.seek(id, to: fraction)
    }
}
