// One page of Settings: the app's page behind a native scroll view of flush groups, under
// a large title that collapses as it scrolls, its rows clear of the safe areas at both
// ends so nothing is clipped.

import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                // Scrolled to its end, the last row stops a clear gap above the floating
                // tab bar rather than at its edge, where the glass blurs it.
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)
            // Opposite-scheme theme previews can pass beneath the tab bar. Let iOS
            // separate the scrolling content from its controls with an opaque edge.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}
