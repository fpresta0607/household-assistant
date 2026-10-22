// The small green dot that says something is connected, with no word beside it: a
// connector, its sign-ins, and this iPhone's link to its gateway. VoiceOver still says
// Connected, so the meaning is not only a colour.

import SwiftUI

struct StatusDot: View {
    /// Grows with the footnote it sits beside, so it stays level with the words.
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Palette.connected)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Connected")
    }
}
