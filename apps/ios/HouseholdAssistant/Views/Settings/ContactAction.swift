// One of the actions under a contact page's face, Message, Call or Photo: a symbol over its name
// on the page's own raised surface, the same fill as the groups under it in either mode,
// with the scheme's rim (GlassRim). Clear glass let the navy through in the dark, so the
// buttons did not match the page round them. It grows with its name at larger text sizes
// rather than clip it, and at the accessibility sizes, where the actions stack, it takes
// the page's full width.

import SwiftUI

struct ContactAction: View {
    let title: String
    let symbol: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Palette.highlight)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 76, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 58)
        .background(Palette.surface, in: shape)
        .overlay {
            GlassRim(shape: shape)
        }
        .contentShape(shape)
    }
}
