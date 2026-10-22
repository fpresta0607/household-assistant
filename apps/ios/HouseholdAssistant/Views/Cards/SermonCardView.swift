// A sermon from the household's archive, on the same parchment as scripture but in wine:
// its title in the system serif, how long it runs, a line from it in italics, and Read the
// sermon when it has a page.

import SwiftUI

struct SermonCardView: View {
    let sermon: SermonCard

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sermon.title)
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if let minutes = sermon.minutes {
                    Text("\(minutes) MIN")
                        .font(.caption2.weight(.heavy))
                        .tracking(0.8)
                        .foregroundStyle(CardStyle.wine)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(CardStyle.wine.opacity(0.1), in: Capsule())
                        .accessibilityLabel("\(minutes) minutes")
                }
            }
            if let quote = sermon.quote {
                Text(verbatim: "\u{201C}\(quote)\u{201D}")
                    .font(.system(.subheadline, design: .serif).italic())
                    .lineSpacing(4)
            }
            if let link = sermon.link {
                Button {
                    openURL(link)
                } label: {
                    Text("Read the sermon")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.glassProminent)
                .tint(CardStyle.wine)
                .padding(.top, 4)
            }
        }
        .foregroundStyle(CardStyle.parchmentInk)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [CardStyle.parchmentTop, CardStyle.parchmentBottom], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CardStyle.wine.opacity(0.3))
        }
        .shadow(color: CardStyle.wine.opacity(0.1), radius: 9, y: 6)
    }
}
