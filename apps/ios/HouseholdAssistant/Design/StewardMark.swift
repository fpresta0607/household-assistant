// The app's own mark: Steward AI's icon, the house with the gold star, cut to the shape
// iOS gives an icon. It stands wherever the app shows itself rather than a person.

import SwiftUI

struct StewardMark: View {
    var size: CGFloat = 88

    var body: some View {
        Image("StewardIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: Palette.shadow, radius: size * 0.16, y: size * 0.06)
            .accessibilityHidden(true)
    }
}
