// The family room's quiet sign that the two assistants are coordinating: a small glass pill
// near the top of the room, "Corey & Denise · 4 min ago" beside both faces, while their
// direct line moved within the last hour (PairRecency). Not a message: nothing in the
// thread moves for it. A tap opens the Corey & Denise group.

import SwiftUI

struct PairMarker: View {
    let onOpen: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let lastAt = model.room.pairLastAt
        // Read again each minute, so "4 min ago" moves on and the pill goes after an hour.
        TimelineView(.everyMinute) { context in
            if let lastAt, let ago = PairRecency.words(lastAt: lastAt, now: context.date) {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        PairFaces(size: 18)
                        Text(verbatim: "\(model.pairName) \u{00B7} \(ago)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 10)
                    .padding(.vertical, 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .rainbowGlass(in: Capsule(), isInteractive: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.pairName), active \(ago)")
                .accessibilityHint("Shows what the two assistants passed to each other")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("pair.marker")
                .transition(Motion.popTransition(reduced: reduceMotion))
            }
        }
    }
}
