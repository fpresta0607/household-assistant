// The widgets' page: the app's own light page with its faint rainbow washes, edged with
// the rainbow sheen the app's glass carries, or the navy in the dark, edged with the dark's
// gold glass, as the app ships them. On a tinted or clear
// Home Screen and on the Lock Screen, iOS takes it away and draws its own.

import SwiftUI

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshBackground()
            .overlay {
                ContainerRelativeShape()
                    .strokeBorder(colorScheme == .dark ? Palette.rim(rainbow: RimStyle.standard.dark) : Palette.sheen, lineWidth: 1.5)
                    .opacity(colorScheme == .dark ? 0.35 : 0.6)
            }
    }
}
