// Copies a card's text to the clipboard, and says so for a moment: the symbol turns to a
// tick and the title to "Copied". The caller picks how it looks with a label style and a
// button style.

import SwiftUI
import UIKit

struct CopyButton: View {
    let text: String
    var title = "Copy"

    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isCopied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            isCopied = true
        } label: {
            Label(isCopied ? "Copied" : title, systemImage: isCopied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .animation(Motion.press(reduced: reduceMotion), value: isCopied)
        .haptic(.success, trigger: isCopied) { _, copied in copied }
        .task(id: isCopied) {
            guard isCopied else {
                return
            }
            try? await Task.sleep(for: .seconds(1.6))
            isCopied = false
        }
    }
}
