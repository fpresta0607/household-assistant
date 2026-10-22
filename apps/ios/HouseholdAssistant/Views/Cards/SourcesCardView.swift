// Where a web search answer came from: one small teal chip per page, named by its title
// or its site, each with a square of the rainbow, wrapping onto a new line as they fill
// the bubble. A tap opens the page.

import SwiftUI

struct SourcesCardView: View {
    let sources: SourcesCard

    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(Array(sources.links.enumerated()), id: \.offset) { index, link in
                Link(destination: link.url) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(LinearGradient(
                                colors: [CardStyle.lightHue(index), CardStyle.hue(index)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 14, height: 14)
                        Text(link.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(CardStyle.searchInk)
                    .padding(.leading, 5)
                    .padding(.trailing, 9)
                    .padding(.vertical, 4)
                    .frame(maxWidth: 220, alignment: .leading)
                    .background(CardStyle.searchTeal.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel("Source: \(link.name)")
                .accessibilityHint("Opens the page")
            }
        }
    }
}
