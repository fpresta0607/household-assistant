// The welcome's mark as Steward AI opens, the motion of the mockup on the owner's review
// page: the mark rises out of the glass from a little smaller on a soft spring, its rim
// draws itself round it, the star in the house glimmers gold as a thin gold ring breathes
// out, and one light glides across it, all of it over within nine tenths of a second. The
// rim is the scheme's own, as on every piece of glass (GlassRim): the rainbow sheen in the
// light and gold glass in the dark. With Reduce Motion the mark only fades in.
//
// It plays the first time it shows and stands still from then on, which is how App Lock
// shows it while Face ID answers. Each moment is worked out from the time since it first
// showed, so the motion is the same on every phone and nothing runs once it is over.

import SwiftUI

struct WelcomeMark: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rims) private var rims
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var shownAt = Date()
    @State private var isOver = false

    private static let size: CGFloat = 112
    /// When the last part, the ring, has faded out.
    private static let length = 0.9
    /// Where the star sits in the icon, as a share of its width and height.
    private static let star = UnitPoint(x: 0.498, y: 0.479)

    var body: some View {
        TimelineView(.animation(paused: isOver)) { timeline in
            mark(at: isOver ? .infinity : timeline.date.timeIntervalSince(shownAt))
        }
        .task {
            try? await Task.sleep(for: .seconds(Self.length))
            isOver = true
        }
    }

    /// The mark `seconds` after it first showed.
    private func mark(at seconds: Double) -> some View {
        let size = Self.size
        let rimSize = size + 8
        let rimShape = RoundedRectangle(cornerRadius: rimSize * 0.2237, style: .continuous)
        let paint = rims.glass(isDark: colorScheme == .dark)
        let rising = Self.progress(seconds, from: 0, lasting: 0.36)
        let drawing = Self.easeOut(Self.progress(seconds, from: 0.12, lasting: 0.5))
        let glimmer = Self.progress(seconds, from: 0.3, lasting: 0.5)
        let ring = Self.progress(seconds, from: 0.42, lasting: 0.48)
        let glide = Self.easeInOut(Self.progress(seconds, from: 0.38, lasting: 0.48))
        let isMoving = !reduceMotion
        return ZStack {
            if isMoving {
                rimShape
                    .stroke(Palette.gold, lineWidth: 1.5)
                    .frame(width: rimSize, height: rimSize)
                    .scaleEffect(1 + 0.32 * Self.easeOut(ring))
                    .opacity(ring > 0 ? 0.7 * (1 - ring) : 0)
            }
            StewardMark(size: size)
                .overlay {
                    if isMoving {
                        light(glimmer: glimmer, glide: glide)
                    }
                }
            rimShape
                .trim(from: 0, to: isMoving ? drawing : 1)
                .stroke(paint.gradient, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: rimSize, height: rimSize)
                .opacity(drawing > 0 || !isMoving ? paint.opacity : 0)
        }
        .scaleEffect(isMoving ? 0.86 + 0.14 * Self.springOut(rising) : 1)
        .opacity(isMoving ? min(1, rising / 0.6) : Self.progress(seconds, from: 0, lasting: 0.2))
        .accessibilityHidden(true)
    }

    /// The gold glimmer on the star and the light gliding across, inside the mark's shape.
    private func light(glimmer: Double, glide: Double) -> some View {
        let size = Self.size
        return ZStack {
            RadialGradient(
                colors: [Palette.rimGold[1], Palette.rimGold[3].opacity(0.8), Palette.gold.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: size * 0.36
            )
            .frame(width: size * 1.1, height: size * 1.1)
            .scaleEffect(0.5 + glimmer)
            .opacity(glimmer < 0.3 ? glimmer / 0.3 : (1 - glimmer) / 0.7)
            .blendMode(.screen)
            .position(x: size * Self.star.x, y: size * Self.star.y)
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: size * 0.45, height: size * 1.6)
                .rotationEffect(.degrees(18))
                .offset(x: size * (2.2 * glide - 1.1))
                .opacity(glide > 0 && glide < 1 ? 0.55 : 0)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .allowsHitTesting(false)
    }

    /// How far `seconds` is through a part that starts at `start` and lasts `length`, from
    /// 0 to 1.
    private static func progress(_ seconds: Double, from start: Double, lasting length: Double) -> Double {
        min(max((seconds - start) / length, 0), 1)
    }

    /// Quick, then settling.
    private static func easeOut(_ share: Double) -> Double {
        1 - pow(1 - share, 3)
    }

    /// Slow at both ends.
    private static func easeInOut(_ share: Double) -> Double {
        share < 0.5 ? 4 * pow(share, 3) : 1 - pow(-2 * share + 2, 3) / 2
    }

    /// A little past the end and back, as a soft spring settles.
    private static func springOut(_ share: Double) -> Double {
        let overshoot = 1.70158
        return 1 + (overshoot + 1) * pow(share - 1, 3) + overshoot * pow(share - 1, 2)
    }
}
