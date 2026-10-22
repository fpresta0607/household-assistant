// One face in a widget, cut to a circle: an assistant's in its ring, the way the app draws
// it (AssistantAvatar), gold unless its person picked another, and a person's plain. A
// tinted widget has no gold, so there the ring is left off.

import SwiftUI
import UIKit
import WidgetKit

struct WidgetFace: View {
    let look: FaceTile.Look
    var photo: UIImage?
    let size: CGFloat
    /// The ring picked for an assistant on the phone; nil draws gold.
    var ring: RingColor?

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        WidgetFaceTile(look: look, photo: photo, size: size)
            .clipShape(Circle())
            .overlay {
                if case .assistant = look, renderingMode == .fullColor {
                    Circle()
                        .strokeBorder(
                            ring.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Palette.gold,
                            lineWidth: max(1.5, size * 0.035)
                        )
                }
            }
    }
}
