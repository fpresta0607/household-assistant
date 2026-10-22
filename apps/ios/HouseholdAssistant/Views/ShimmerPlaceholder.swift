// What a picture's box shows until the picture arrives: the box already at its final
// size, so the thread never jumps when it loads. It holds still: a light sweeping across
// every box still loading redrew each of them on every frame, for as long as a picture
// took, or forever for one that never came.

import SwiftUI

struct ShimmerPlaceholder: View {
    var body: some View {
        Rectangle()
            .fill(Palette.surface)
            .accessibilityLabel("Loading")
    }
}
