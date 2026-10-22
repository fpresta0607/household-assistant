// A fade for an overlay that takes no touch once it starts to go. The message menu's
// backdrop, still fading out after Copy, took the tap meant for the composer under it.

import SwiftUI

struct FadeAway: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .allowsHitTesting(phase != .didDisappear)
    }
}
