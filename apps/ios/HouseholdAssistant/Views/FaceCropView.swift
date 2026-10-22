// Cutting a face to a circle, as Contacts does: the photo fills the circle, and the person
// drags and pinches it into place. What is inside the circle is kept, `side` pixels square.
//
// The circle is placed once, in the one space the whole screen is drawn in, bars and all,
// and the photo, the dimming's hole, the outline and the square kept all come from it
// (FaceCrop). Nothing is laid out against the safe area on its own, so the outline, the
// bright circle and the face saved cannot drift apart.

import SwiftUI

struct FaceCropView: View {
    let image: UIImage
    let name: String
    let onChoose: (Data) -> Void

    /// The kept face's width and height, in pixels: sharp in the largest place a face
    /// shows, and far under the gateway's megabyte.
    static let side = 512
    private static let diameter: CGFloat = 300

    @Environment(\.dismiss) private var dismiss
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var scale: CGFloat
    @State private var settledScale: CGFloat
    @State private var offset: CGSize
    @State private var settledOffset: CGSize

    /// `scale` and `offset` start the photo where a person might have left it, for the
    /// screenshots; the offset is in points from the circle's centre.
    init(
        image: UIImage,
        name: String,
        scale: CGFloat = 1,
        offset: CGSize = .zero,
        onChoose: @escaping (Data) -> Void
    ) {
        self.image = image
        self.name = name
        self.onChoose = onChoose
        _scale = State(initialValue: scale)
        _settledScale = State(initialValue: scale)
        _offset = State(initialValue: offset)
        _settledOffset = State(initialValue: offset)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let circle = Self.circle(in: proxy.size)
                let photo = crop(in: circle).photoFrame
                ZStack {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: photo.width, height: photo.height)
                        .position(x: photo.midX, y: photo.midY)
                    // Outside the circle is dimmed, so what is kept is plain to see.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        path.addEllipse(in: circle)
                    }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Path(ellipseIn: circle)
                        .stroke(.white.opacity(0.8), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(drag(settlingIn: circle).simultaneously(with: pinch(settlingIn: circle)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name)'s new face")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Choose") {
                            onChoose(cropped(crop(in: circle)))
                            dismiss()
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .navigationTitle("Move and Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// The circle, `diameter` across in the middle of the screen.
    private static func circle(in size: CGSize) -> CGRect {
        CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2, width: diameter, height: diameter)
    }

    /// The photo under `circle`, moved and scaled as the person has left it.
    private func crop(in circle: CGRect) -> FaceCrop {
        FaceCrop(
            imageSize: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale),
            circle: circle,
            scale: scale,
            offset: offset
        )
    }

    private func drag(settlingIn circle: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                settle(in: circle)
            }
    }

    private func pinch(settlingIn circle: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                settle(in: circle)
            }
    }

    /// Keeps the photo covering the whole circle: it springs back to the nearest place
    /// that leaves no gap.
    private func settle(in circle: CGRect) {
        let settled = crop(in: circle).settled
        withAnimation(Motion.arrive(reduced: reduceMotion)) {
            offset = settled.offset
        }
        settledOffset = offset
        settledScale = scale
    }

    /// What the circle covers, as a JPEG `side` pixels square, drawn from the photo itself.
    private func cropped(_ crop: FaceCrop) -> Data {
        let kept = crop.kept
        let side = CGFloat(Self.side)
        let magnification = side / kept.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .jpegData(withCompressionQuality: 0.85) { _ in
                image.draw(in: CGRect(
                    x: -kept.minX * magnification,
                    y: -kept.minY * magnification,
                    width: crop.imageSize.width * magnification,
                    height: crop.imageSize.height * magnification
                ))
            }
    }
}
