// The halo under a face or a dot on a map while it is live: a soft disc of the person's
// colour. It holds still, so a live map in a thread costs nothing while it sits there.

import SwiftUI

struct MapPulse: View {
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(Palette.highlight.opacity(0.22))
            .frame(width: size * 1.6, height: size * 1.6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
