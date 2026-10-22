// The way back to the newest message from reading above it, as in Messages and Telegram: a
// glass circle with a down arrow over the end of the thread, there only while the list
// stands well above its newest row.

import SwiftUI

struct JumpToNewestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .rainbowGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to the newest message")
        .accessibilityIdentifier("thread.jumpToNewest")
    }
}
