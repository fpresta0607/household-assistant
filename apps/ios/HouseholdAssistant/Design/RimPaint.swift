// One rim as it is drawn: its colours round the shape from the angle they start at, how
// strongly, and the gradient made of them, built once with the look (RimLook) rather than
// in every bubble.

import SwiftUI

struct RimPaint {
    let colors: [Color]
    let opacity: Double
    let gradient: AngularGradient

    init(colors: [Color], angle: Angle, opacity: Double) {
        self.colors = colors
        self.opacity = opacity
        // The first colour again at the end, so the rim closes without a seam.
        gradient = AngularGradient(colors: colors + colors.prefix(1), center: .center, angle: angle)
    }
}
