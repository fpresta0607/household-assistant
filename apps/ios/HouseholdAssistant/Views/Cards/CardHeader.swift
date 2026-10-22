// The top of a small card: a tinted symbol, what kind of card it is, and its title.

import SwiftUI

struct CardHeader: View {
    let symbol: String
    let tint: Color
    let kind: String
    let title: String?
    /// A note at the far end, such as who sees a tick.
    var note: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(CardStyle.secondaryInk)
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CardStyle.ink)
                }
            }
            Spacer(minLength: 4)
            if let note {
                Text(note)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CardStyle.accent)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
