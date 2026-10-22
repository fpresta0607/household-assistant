// A screen opening out of what was tapped and closing back into it, with iOS's own zoom: a
// picture out of its place in the grid, Location out of its chip, and what an assistant
// changed out of its chip. A conversation slides in instead (CFO notes section 9), since
// shrinking it back into its face drew it as a white card. What was tapped is marked with
// `zoomSource`. With Reduce Motion the screen opens the plain way, with no zoom.

import SwiftUI

struct ZoomTransition<ID: Hashable>: ViewModifier {
    let sourceID: ID
    let namespace: Namespace.ID

    @Environment(\.reducesMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}

extension View {
    /// Opens this screen out of the `zoomSource` marked `sourceID` in `namespace`, and closes
    /// it back into it.
    func zoomTransition<ID: Hashable>(from sourceID: ID, in namespace: Namespace.ID) -> some View {
        modifier(ZoomTransition(sourceID: sourceID, namespace: namespace))
    }
}
