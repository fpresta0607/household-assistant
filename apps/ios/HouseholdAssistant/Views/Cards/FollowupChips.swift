// What the person may ask next, under the assistant's newest answer: up to three glass
// chips, each with its icon in gold, sliding in one after another once the answer is
// in. A tap sends a chip's words as the person's next message, and once that is sent
// the chips are gone, since they belong to the newest answer only. With Reduce Motion
// they fade in together.

import SwiftUI

struct FollowupChips: View {
    let followups: FollowupsCard
    let conversation: RoomConversation

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isShown = false

    var body: some View {
        ChipFlow(spacing: 8) {
            ForEach(Array(followups.items.enumerated()), id: \.offset) { index, item in
                Button {
                    Task {
                        await model.room.send(item.text, in: conversation)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.goldText)
                        Text(item.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 280, alignment: .leading)
                    .rainbowGlass(in: Capsule(), isInteractive: true)
                }
                .buttonStyle(.plain)
                .opacity(isShown ? 1 : 0)
                .offset(x: isShown || reduceMotion ? 0 : -14)
                .animation(Motion.inTurn(index, delay: 0.08, step: 0.06, reduced: reduceMotion), value: isShown)
                .accessibilityLabel(item.text)
                .accessibilityHint("Sends it to \(model.assistantName)")
            }
        }
        .padding(.top, 8)
        .onAppear {
            isShown = true
        }
    }
}
