// Three dots that rise and fall in turn, like iMessage's, for someone answering. With
// Reduce Motion they hold still.
//
// Each dot's turn is one phase SwiftUI animates to by itself, so the dots are not drawn
// again on every frame, and they move only while someone is answering, the only time
// they are on screen.

import SwiftUI

struct TypingDots: View {
    let color: Color
    var dotSize: CGFloat = 8

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(raised: nil)
            } else {
                PhaseAnimator([0, 1, 2]) { raised in
                    dots(raised: raised)
                } animation: { _ in
                    .easeInOut(duration: 0.28)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The three dots, the one whose turn it is raised and brighter.
    private func dots(raised: Int?) -> some View {
        HStack(spacing: dotSize * 0.6) {
            ForEach(0..<3, id: \.self) { dot in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: dot == raised ? -dotSize / 2 : 0)
                    .opacity(dot == raised ? 0.95 : 0.55)
            }
        }
    }
}
