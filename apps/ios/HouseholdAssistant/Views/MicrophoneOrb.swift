// The composer's microphone: a sphere of Liquid Glass with a royal glyph and a royal rim,
// the biggest control in the bar. Held, it grows under the finger, its glass swelling into
// the recording bar beside it, ripples with the voice in royal rings and follows the
// finger, left towards cancelling and up into the glass lock above it, shrinking as it
// goes in. With Reduce Motion it neither moves nor ripples: a halo brightens with the
// voice instead.
//
// Only the picture: the hold itself is RoomComposer's, which has to start the recorder
// before anything here is drawn.
//
// The glyph is the glass's own content, so it is always drawn on top of the glass, never
// under it. The sphere grows by its size, not by a scale, and the glyph is drawn at the
// size it grows to and only ever scaled down, so both stay sharp, where scaling a small
// drawing up had blurred them.

import SwiftUI

struct MicrophoneOrb: View {
    enum Mode: Equatable {
        case idle
        case holding
    }

    let mode: Mode
    /// 0...1, the voice's level.
    let level: Double
    var cancelProgress: Double = 0
    var lockProgress: Double = 0
    /// The composer's glass, which the sphere flows into the send arrow within.
    let glass: Namespace.ID

    @Environment(\.reducesMotion) private var reduceMotion

    static let size: CGFloat = 62
    /// What it grows to under the finger.
    private static let heldSize: CGFloat = 96
    /// How much bigger than at rest the glyph is drawn: the most it grows.
    private static let drawn = heldSize / size
    /// How far above the microphone the lock's centre sits.
    private static let lockRise: CGFloat = 150

    var body: some View {
        let diameter = Self.size * scale
        ZStack {
            switch mode {
            case .holding:
                ripples
            case .idle:
                EmptyView()
            }
            sphere
        }
        .frame(width: diameter, height: diameter)
        .offset(reduceMotion ? .zero : CGSize(
            width: -cancelProgress * VoiceNoteGesture.cancelDistance,
            height: -lockProgress * VoiceNoteGesture.lockDistance
        ))
        .frame(width: Self.size, height: Self.size)
        .overlay {
            if mode == .holding {
                LockPill(progress: lockProgress)
                    .offset(y: -Self.lockRise)
                    .transition(.opacity)
            }
        }
        .animation(Motion.press(reduced: reduceMotion), value: mode)
    }

    private var scale: CGFloat {
        guard mode == .holding, !reduceMotion else {
            return 1
        }
        return Self.heldSize / Self.size * (1 - 0.4 * lockProgress)
    }

    private var sphere: some View {
        symbol
            .scaleEffect(scale / Self.drawn)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlass(.regular.interactive(), in: Circle())
            .overlay { Circle().strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1.5) }
            .glassMorph("voice", in: glass)
    }

    private var symbol: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 26 * Self.drawn, weight: .semibold))
            .foregroundStyle(Palette.highlight)
    }

    /// Two royal rings spreading from the sphere over and over, swelling with the voice.
    @ViewBuilder
    private var ripples: some View {
        if reduceMotion {
            Circle()
                .strokeBorder(Palette.highlight.opacity(0.25 + 0.5 * level), lineWidth: 3)
                .scaleEffect(1.35)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<2, id: \.self) { index in
                        let phase = (seconds / 1.4 + Double(index) / 2).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .strokeBorder(Palette.highlight.opacity(0.6 * (1 - phase)), lineWidth: 2)
                            .scaleEffect(1 + 0.7 * phase + 0.25 * level)
                    }
                }
            }
        }
    }
}

/// The glass lock above a held microphone, open with a chevron bobbing towards it, tinting
/// royal as the finger slides up. With Reduce Motion the chevron holds still.
private struct LockPill: View {
    let progress: Double

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(progress > 0.5 ? Palette.highlight : Palette.text)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.secondaryText)
                    .offset(y: reduceMotion ? 0 : -4 * abs(sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.2)))
            }
            .opacity(1 - progress)
        }
        .padding(.top, 14)
        .frame(width: 46, height: 104, alignment: .top)
        .background(Palette.highlight.opacity(0.28 * progress), in: Capsule())
        .liquidGlass(.regular, in: Capsule())
        .accessibilityHidden(true)
    }
}
