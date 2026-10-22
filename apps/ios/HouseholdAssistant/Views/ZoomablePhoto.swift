// One photo in the viewer: pinch to zoom, double tap to zoom in on where the finger is
// and again to come back out, and drag around it while zoomed in. Zoomed out, a drag is
// the viewer's, to swipe to the next photo or down to close.

import SwiftUI

struct ZoomablePhoto: View {
    let image: UIImage
    @Binding var isZoomed: Bool

    @Environment(\.reducesMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    private static let deepest: CGFloat = 4
    private static let doubleTapScale: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let box = geometry.size
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: box.width, height: box.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(settledScale * value.magnification, 1), Self.deepest)
                            offset = clamped(settledOffset, in: box)
                        }
                        .onEnded { _ in
                            settle(in: box)
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { drag in
                            offset = clamped(
                                CGSize(
                                    width: settledOffset.width + drag.translation.width,
                                    height: settledOffset.height + drag.translation.height
                                ),
                                in: box
                            )
                        }
                        .onEnded { _ in
                            settledOffset = offset
                        },
                    including: isZoomed ? .all : .subviews
                )
                .onTapGesture(count: 2) { location in
                    withAnimation(Motion.press(reduced: reduceMotion)) {
                        if scale > 1 {
                            scale = 1
                            offset = .zero
                        } else {
                            // The tapped point comes to the middle of the screen.
                            scale = Self.doubleTapScale
                            offset = clamped(
                                CGSize(
                                    width: (box.width / 2 - location.x) * scale,
                                    height: (box.height / 2 - location.y) * scale
                                ),
                                in: box
                            )
                        }
                        settledScale = scale
                        settledOffset = offset
                    }
                }
        }
        .onChange(of: scale > 1) { _, zoomed in
            isZoomed = zoomed
        }
        .onDisappear {
            scale = 1
            settledScale = 1
            offset = .zero
            settledOffset = .zero
        }
        .accessibilityElement()
        .accessibilityLabel("Photo")
        .accessibilityAddTraits(.isImage)
        .accessibilityZoomAction { action in
            withAnimation(Motion.press(reduced: reduceMotion)) {
                scale = action.direction == .zoomIn ? min(scale * 2, Self.deepest) : max(scale / 2, 1)
                settledScale = scale
                offset = .zero
                settledOffset = .zero
            }
        }
    }

    /// Below 1 springs back to fitting the screen.
    private func settle(in box: CGSize) {
        withAnimation(Motion.press(reduced: reduceMotion)) {
            if scale <= 1 {
                scale = 1
                offset = .zero
            } else {
                offset = clamped(offset, in: box)
            }
            settledScale = scale
            settledOffset = offset
        }
    }

    /// Never past the photo's own edge: how far the zoomed photo overhangs the screen on
    /// each side is as far it may move.
    private func clamped(_ proposed: CGSize, in box: CGSize) -> CGSize {
        let fitted = fittedSize(in: box)
        let overhangX = max((fitted.width * scale - box.width) / 2, 0)
        let overhangY = max((fitted.height * scale - box.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -overhangX), overhangX),
            height: min(max(proposed.height, -overhangY), overhangY)
        )
    }

    /// The photo's size when it just fits the screen.
    private func fittedSize(in box: CGSize) -> CGSize {
        let aspect = image.size.width / max(image.size.height, 1)
        if box.width / max(box.height, 1) > aspect {
            return CGSize(width: box.height * aspect, height: box.height)
        }
        return CGSize(width: box.width, height: box.width / max(aspect, 0.01))
    }
}
