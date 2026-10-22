// The wide glass bar a note records in, in place of the field: a blinking red dot, or the
// bin once the note is locked, the running clock, and the note's bars as they are heard.
// Over it, "Slide to cancel" shimmers and drifts left with the finger while the note is
// held, and once it is locked a line says how to finish. With Reduce Motion the dot holds
// steady and nothing shimmers or drifts.

import SwiftUI

struct VoiceNoteRecordingBar: View {
    let gesture: VoiceNoteGesture
    /// The levels heard so far, 0...1, newest last.
    let levels: [Double]
    let onDiscard: () -> Void

    @Environment(\.reducesMotion) private var reduceMotion

    /// How many of the newest levels the bar shows, travelling left as more arrive.
    private static let shownLevels = 32

    var body: some View {
        HStack(spacing: 12) {
            if gesture.phase == .locked {
                Button("Delete voice note", systemImage: "trash.fill", action: onDiscard)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .font(.title3)
                    .transition(.scale.combined(with: .opacity))
            } else {
                RecordingDot()
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                Text(VoiceNoteGesture.clock(milliseconds: Int(gesture.elapsed(at: timeline.date) * 1000)))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.text)
            }
            WaveformBars(
                levels: Array((Array(repeating: Waveform.floor, count: Self.shownLevels) + levels).suffix(Self.shownLevels)),
                progress: 1,
                played: Palette.text,
                unplayed: Palette.text
            )
            .frame(height: 30)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 56)
        .liquidGlass(.regular, in: Capsule())
        .overlay(alignment: .top) {
            Group {
                if gesture.phase == .holding {
                    SlideToCancelHint()
                        .opacity(0.6 + 0.4 * gesture.cancelProgress)
                        .offset(x: reduceMotion ? 0 : -24 * gesture.cancelProgress)
                        .accessibilityLabel("Slide left to cancel")
                } else {
                    Text("Locked. Tap send when you are done.")
                        .font(.subheadline)
                }
            }
            .foregroundStyle(Palette.text)
            .offset(y: -30)
            .transition(.opacity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording a voice note")
        .onAppear {
            ChatTiming.recordingShown()
        }
    }
}

/// The red dot of a note recording, blinking. With Reduce Motion it stays lit.
private struct RecordingDot: View {
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            Circle()
                .fill(Color.red)
                .frame(width: 11, height: 11)
                .opacity(reduceMotion ? 1 : 0.3 + 0.7 * abs(cos(context.date.timeIntervalSinceReferenceDate * .pi)))
        }
        .accessibilityHidden(true)
    }
}

/// "Slide to cancel" with its chevrons, a soft light sweeping across the words over and
/// over while the note records. With Reduce Motion the words hold still.
private struct SlideToCancelHint: View {
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isSweeping = false

    var body: some View {
        words
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, Palette.pageWarm.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.45)
                        .offset(x: isSweeping ? geometry.size.width : -geometry.size.width * 0.45)
                    }
                    .mask {
                        words
                    }
                    .onAppear {
                        withAnimation(Motion.shimmer) {
                            isSweeping = true
                        }
                    }
                }
            }
    }

    private var words: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left.2")
                .font(.caption.weight(.semibold))
            Text("Slide to cancel")
                .font(.subheadline)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
