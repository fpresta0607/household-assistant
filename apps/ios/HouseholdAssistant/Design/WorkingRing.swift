// The working line's icon in a turning ring: what an assistant is busy with while its
// run uses a tool, in Talk and in the thread. A budget shows PocketPiggies' pig, since
// there is no SF Symbol for a pig, and thinking shows sparkles. With Reduce Motion the
// ring stands still.
//
// The arc turns by a rotation SwiftUI animates by itself, so nothing is drawn again each
// frame, and it turns only while the ring is on screen, which is only while the assistant
// works.

import SwiftUI

struct WorkingRing: View {
    /// Nil while the assistant thinks.
    let activity: AssistantActivity?

    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isTurning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.highlight.opacity(0.14), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Palette.highlight, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(isTurning ? 270 : -90))
                .animation(isTurning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : nil, value: isTurning)
            if activity == .budget {
                PiggyMark()
                    .frame(width: 17, height: 17)
            } else {
                Image(systemName: activity?.symbol ?? "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.highlight)
            }
        }
        .frame(width: 26, height: 26)
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            isTurning = !reduced
        }
        .accessibilityHidden(true)
    }
}
