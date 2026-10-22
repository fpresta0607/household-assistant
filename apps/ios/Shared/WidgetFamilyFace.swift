// The family room's face in a widget: the four who are in it, each in a quarter of one
// circle, seated the way the app seats them (FamilyFaces), which the snapshot keeps.

import SwiftUI
import UIKit

struct WidgetFamilyFace: View {
    let faces: [WidgetSnapshot.Face]
    let photos: [String: UIImage]
    let size: CGFloat

    var body: some View {
        let seated = Array(faces.prefix(4))
        Group {
            if seated.isEmpty {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(Palette.highlight)
                    .frame(width: size, height: size)
                    .background(Palette.surface)
            } else {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        quarter(seated, 0)
                        quarter(seated, 1)
                    }
                    GridRow {
                        quarter(seated, 2)
                        quarter(seated, 3)
                    }
                }
            }
        }
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.75), lineWidth: max(1, size * 0.025))
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func quarter(_ seated: [WidgetSnapshot.Face], _ index: Int) -> some View {
        if index < seated.count {
            WidgetFaceTile(look: FaceTile.Look(seated[index]), photo: photos[seated[index].id], size: size / 2)
        } else {
            Rectangle()
                .fill(Palette.surface)
                .frame(width: size / 2, height: size / 2)
        }
    }
}
