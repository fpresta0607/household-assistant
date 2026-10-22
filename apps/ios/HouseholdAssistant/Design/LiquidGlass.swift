// One material for controls, pills and cards. Seasonal surfaces have a stable base
// under the glass so text contrast never depends on the message scrolling behind it.
import SwiftUI

struct LiquidGlass<Surface: Shape>: ViewModifier {
    let glass: Glass
    let shape: Surface
    @Environment(\.accessibilityReduceTransparency) private var isTransparencyReduced
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if let palette = ThemeSelection.shared.palette(for: scheme) {
            content
                .background(Color(themeRGB: palette.surface), in: shape)
                .glassEffect(isTransparencyReduced ? .identity : glass.tint(Color(themeRGB: palette.surface)), in: shape)
        } else if isTransparencyReduced {
            content.background(.regularMaterial, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    func liquidGlass(_ glass: Glass = .regular, in shape: some Shape) -> some View {
        modifier(LiquidGlass(glass: glass, shape: shape))
    }
}
