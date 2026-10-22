// A main action the way the owner's accent rule has it: the button is glass, and its accent
// is only its words and its rim, never a fill. Its label sets its own weight, bold for the
// one action that matters most.

import SwiftUI

extension View {
    /// A glass button whose words and rim are `accent`.
    func accentGlass(_ accent: Color) -> some View {
        buttonStyle(.glass)
            .foregroundStyle(accent)
            .overlay {
                Capsule()
                    .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
