// The end of a Settings row: its value, a small spinner in its place while a change is on
// its way to the gateway, and a chevron when the row opens a page.

import SwiftUI

struct RowValue: View {
    var text: String?
    var isPending = false
    var opensPage = true

    var body: some View {
        HStack(spacing: 6) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
            }
            if let text {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            if opensPage {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.text.opacity(0.3))
                    .accessibilityHidden(true)
            }
        }
    }
}
