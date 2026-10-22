// Where a card will be, while its block is still arriving: a pale panel with a few soft
// lines, holding still. Never the JSON.

import SwiftUI

struct PendingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(width: 110)
            line(width: 230)
            line(width: 170)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPanel()
        .accessibilityElement()
        .accessibilityLabel("A card is on its way")
    }

    private func line(width: CGFloat) -> some View {
        Capsule()
            .fill(CardStyle.ink.opacity(0.08))
            .frame(maxWidth: width)
            .frame(height: 10)
    }
}
