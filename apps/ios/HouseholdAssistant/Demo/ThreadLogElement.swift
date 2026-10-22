#if DEBUG
// The thread list's newest log lines as one element nobody sees, for a UI test to read and
// put in its failure message (ThreadLog).

import SwiftUI

struct ThreadLogElement: View {
    var body: some View {
        Text(ThreadLog.Lines.shared.newest.joined(separator: " | "))
            .font(.system(size: 1))
            .lineLimit(1)
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("debug.threadLog")
    }
}
#endif
