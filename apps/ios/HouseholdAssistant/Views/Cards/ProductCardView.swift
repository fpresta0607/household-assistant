// Something to buy: its picture, name, price in gold, the store, and Open and Copy link.

import SwiftUI

struct ProductCardView: View {
    let product: ProductCard

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            picture
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CardStyle.ink)
                if let price = product.price {
                    Text(price)
                        .font(.footnote.weight(.heavy))
                        .foregroundStyle(CardStyle.goldInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(CardStyle.gold.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let store = product.store {
                    Text(store)
                        .font(.caption)
                        .foregroundStyle(CardStyle.secondaryInk)
                }
                if let url = product.url {
                    HStack(spacing: 8) {
                        Button {
                            openURL(url)
                        } label: {
                            Text("Open")
                                .fontWeight(.bold)
                        }
                        .accentGlass(CardStyle.accent)
                        CopyButton(text: url.absoluteString, title: "Copy link")
                            .labelStyle(.titleOnly)
                            .buttonStyle(.glass)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardPanel()
    }

    private var picture: some View {
        CardPicture(url: product.image, size: CGSize(width: 70, height: 86)) {
            Image(systemName: "bag")
                .font(.title2)
                .foregroundStyle(CardStyle.goldInk.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [CardStyle.hex(0xFDF6EA), CardStyle.hex(0xEFE2CB)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}
