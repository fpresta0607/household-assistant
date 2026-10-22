// A block the app cannot draw as a card, an unknown type or JSON that does not read, shown
// as the text it is, so nothing the assistant said is lost.

import SwiftUI

struct CodeBlockCard: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(CardStyle.ink)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPanel()
    }
}
