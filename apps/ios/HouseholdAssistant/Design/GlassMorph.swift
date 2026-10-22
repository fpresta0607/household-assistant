// Glass that flows into its next form: inside one GlassEffectContainer, iOS 26 morphs glass
// that goes by the same id from one shape into the next, and lets new glass well out of
// the glass beside it. The composer's field becomes the bar a note records in, the
// microphone becomes the send arrow, and the apps drawer wells out of the plus.
//
// With Reduce Motion, or with Reduce Transparency, where the glass is the light material
// (LiquidGlass), nothing morphs: the pieces only fade.

import SwiftUI

struct GlassMorph<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID

    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var isTransparencyReduced

    func body(content: Content) -> some View {
        if reduceMotion || isTransparencyReduced {
            content
        } else {
            content.glassEffectID(id, in: namespace)
        }
    }
}

extension View {
    /// Morphs this piece's glass with any other going by `id` in `namespace`. Applied after
    /// its `liquidGlass`.
    func glassMorph<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        modifier(GlassMorph(id: id, namespace: namespace))
    }
}
