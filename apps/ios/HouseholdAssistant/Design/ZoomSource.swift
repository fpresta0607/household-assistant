// Marks what a screen zooms out of and back into (ZoomTransition), in a namespace that may
// not be there: a picture in a bubble zooms into the viewer only where the screen showing
// it opens the viewer, which says so through `mediaZoom`. Anywhere else it is only itself.

import SwiftUI

struct ZoomSource<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Marks this as what the screen with `id` zooms out of, in `namespace` when there is one.
    func zoomSource<ID: Hashable>(_ id: ID, in namespace: Namespace.ID?) -> some View {
        modifier(ZoomSource(id: id, namespace: namespace))
    }
}

extension EnvironmentValues {
    /// Where the pictures below zoom into the viewer from, set by the screen that opens it.
    @Entry var mediaZoom: Namespace.ID? = nil
}
