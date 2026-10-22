// Floating glass uses the same preset rim as chat bubbles. Default retains its
// original rainbow sheen in Light and gold in Dark.

import SwiftUI

struct GlassRim<Rim: InsettableShape>: View {
    let shape: Rim

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rims) private var rims

    var body: some View {
        let paint = rims.glass(isDark: colorScheme == .dark)
        shape.strokeBorder(paint.gradient, lineWidth: 1.2)
            .opacity(paint.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
