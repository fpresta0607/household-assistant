// What a face in a widget is made of, before it is cut to a circle or a quarter of one:
// the photo the app drew for the notifications when one was chosen, over the initial or
// emoji the app draws (FaceTile).
//
// On a tinted or clear Home Screen and on the Lock Screen, iOS draws a widget in one or
// two tints, where a filled tile would be a blank disc and a photo a dim, soft blot. There
// the tile is its initial or emoji on a faint wash, and the photo is left for full colour.

import SwiftUI
import UIKit
import WidgetKit

struct WidgetFaceTile: View {
    let look: FaceTile.Look
    let photo: UIImage?
    let size: CGFloat

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            if renderingMode == .fullColor {
                FaceTile(look: look, size: size)
            } else {
                Rectangle()
                    .fill(.quaternary)
                glyph
            }
            if let photo, renderingMode == .fullColor {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch look {
        case .ownPerson(let initial), .otherPerson(let initial):
            Text(initial)
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
        case .assistant(let emoji?):
            Text(emoji)
                .font(.system(size: size * 0.5))
        case .assistant(nil):
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.36, weight: .semibold))
        }
    }
}

extension FaceTile.Look {
    /// Somebody in the room as the snapshot has them, drawn as who they are to this phone.
    init(_ face: WidgetSnapshot.Face) {
        let initial = String(face.name.prefix(1)).uppercased()
        if face.isAssistant {
            self = .assistant(emoji: face.emoji)
        } else if face.isOwner {
            self = .ownPerson(initial: initial)
        } else {
            self = .otherPerson(initial: initial)
        }
    }
}
