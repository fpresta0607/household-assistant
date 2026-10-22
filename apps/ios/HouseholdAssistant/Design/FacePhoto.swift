// A face chosen from Photos, as the gateway keeps it: read through the media cache like
// any picture, and drawn over `placeholder` once it has loaded. Until then, or if it
// cannot be read, the placeholder is the face.

import SwiftUI

struct FacePhoto<Placeholder: View>: View {
    let media: RoomMedia
    let size: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            placeholder()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .animation(Motion.fade, value: image)
        .task(id: media.id) {
            guard let file = try? await model.media.url(for: media) else {
                return
            }
            image = await MediaThumbnails.image(for: file, isVideo: false, pixels: size * displayScale)
        }
    }
}
