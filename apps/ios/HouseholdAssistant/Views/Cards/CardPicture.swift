// A card's picture from the web, such as a product's: read through the same loader as the
// room's photos, decoded no larger than it is drawn and kept, so a card scrolled past
// again draws it at once. Until it has loaded, or when there is none, the placeholder
// is the picture.

import SwiftUI

struct CardPicture<Placeholder: View>: View {
    let url: URL?
    let size: CGSize
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await MediaThumbnails.image(at: url, pixels: max(size.width, size.height) * displayScale)
        }
    }
}
