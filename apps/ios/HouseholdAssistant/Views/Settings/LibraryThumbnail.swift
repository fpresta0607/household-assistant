// A photo of the person's library as a small square, for the photo keeper's recap grid and
// clean-out review: decoded at the size it is drawn, from what the phone already has.

import Photos
import SwiftUI

struct LibraryThumbnail: View {
    let id: String
    var side: CGFloat = 76
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Palette.text.opacity(0.08))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: id) {
                image = await Self.load(id, pixels: side * displayScale)
            }
    }

    private static func load(_ id: String, pixels: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
