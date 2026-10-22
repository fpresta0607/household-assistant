// Liquid Glass with the rim the new look gives every floating piece: the header's pill,
// the Talk button, the pins, the reaction bar and its menu, the chips, the call bar and
// today's line on Chats. The rim (GlassRim) is the soft rainbow in the light and gold
// glass in the dark, a tint on iOS's own glass, never in place of it, and with Reduce
// Transparency it edges the light material instead (LiquidGlass).

import SwiftUI

struct RainbowGlass<Rim: InsettableShape>: ViewModifier {
    let shape: Rim
    var isInteractive = false

    func body(content: Content) -> some View {
        content
            .liquidGlass(isInteractive ? Glass.regular.interactive() : Glass.regular, in: shape)
            .overlay {
                GlassRim(shape: shape)
            }
    }
}

extension View {
    /// Frosted glass in `shape`, edged with the scheme's rim.
    func rainbowGlass<Rim: InsettableShape>(in shape: Rim, isInteractive: Bool = false) -> some View {
        modifier(RainbowGlass(shape: shape, isInteractive: isInteractive))
    }
}

extension EnvironmentValues {
    /// Every rim the look draws, for each scheme, worked out once from Appearance.
    /// `PhonePreferences` sets it at the root.
    @Entry var rims = RimLook()
}
