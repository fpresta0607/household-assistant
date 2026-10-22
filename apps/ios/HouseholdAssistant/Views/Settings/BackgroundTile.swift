// A chat background as a small page to choose, outlined in the highlight once chosen: on
// Appearance for this phone, and on the family room's page for both phones.

import SwiftUI

struct BackgroundTile<Background: View>: View {
    let isChosen: Bool
    let background: Background

    init(isChosen: Bool, @ViewBuilder background: () -> Background) {
        self.isChosen = isChosen
        self.background = background()
    }

    var body: some View {
        background
            .frame(width: 52, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isChosen ? Palette.highlight : Palette.text.opacity(0.1), lineWidth: isChosen ? 2.5 : 0.5)
            }
    }
}
