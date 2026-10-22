// One thing the assistant can do with a connector or one of its accounts, as a plain line
// after a small gold tick: gold is the assistants' own, and only a glyph here.

import SwiftUI

struct AssistantAbility: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(Palette.text)
        } icon: {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Palette.goldText)
        }
        .font(.subheadline)
    }
}
