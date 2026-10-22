// The rim round an assistant's bubble. Corey's and Denise's bubbles keep their light fill,
// and the rim is a still stroke of the bubble's own shape, gold running into the rainbow
// round it in the light and gold glass alone in the dark, each as Appearance sets it. The
// working line an assistant shows while it uses a tool (TypingBubble) wears the same rim,
// so it matches the bubbles round it.
//
// It never moves. A light running round every assistant's bubble redrew each of them on
// every frame for as long as they were on screen, which the thread paid for in scrolling.
// Nor does it mix its own colours: every bubble draws the one rim worked out for the look
// at the root (RimLook).

import SwiftUI

private let rimWidth: CGFloat = 1.6

struct AssistantRim<Rim: Shape>: View {
    let shape: Rim

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rims) private var rims

    var body: some View {
        let paint = rims.bubble(isDark: colorScheme == .dark)
        shape.stroke(paint.gradient, lineWidth: rimWidth)
            .opacity(paint.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
