// A gate code, an address, a link or a price, set large enough to read across a room,
// with one button that copies it.

import SwiftUI

struct CopyCardView: View {
    let copy: CopyCard

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let label = copy.label {
                    Text(label.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(CardStyle.secondaryInk)
                }
                Text(copy.text)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .tracking(copy.text.count <= 12 ? 1.5 : 0)
                    .foregroundStyle(CardStyle.ink)
            }
            Spacer(minLength: 4)
            CopyButton(text: copy.text)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(CardStyle.accent)
                .accessibilityLabel("Copy \(copy.label ?? "it")")
        }
        .padding(.vertical, 10)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .cardPanel()
    }
}
