// A list ticked right in the chat. A tick shows at once and goes to the gateway, which
// keeps it for this phone's assistant to read at the start of its next turn, so its list
// stays in step; the header then says the assistant sees it. Until the gateway has kept
// the reply the list shows as sent and cannot be ticked. A list the lists skill keeps
// wears its mint, ticks included.

import SwiftUI

struct ChecklistCardView: View {
    let checklist: ChecklistCard
    /// Nil until the gateway has kept the message.
    let messageId: String?
    let conversation: RoomConversation
    let isFromLists: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    private func tick(_ item: Int) -> ChecklistTick? {
        messageId.map { ChecklistTick(messageId: $0, cardId: checklist.id, item: item) }
    }

    private func isDone(_ item: Int) -> Bool {
        tick(item).flatMap { model.room.ticks[$0] } ?? checklist.items[item].done
    }

    private var isSeen: Bool {
        checklist.items.indices.contains { tick($0).flatMap { model.room.ticks[$0] } != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(
                symbol: "checklist",
                tint: CardStyle.mint,
                kind: "Checklist",
                title: checklist.title,
                note: isSeen ? "\(model.assistantName) sees it" : nil
            )
            .padding(.bottom, 4)
            ForEach(Array(checklist.items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider()
                        .overlay(CardStyle.hairline)
                }
                row(index, item)
            }
        }
        .padding(12)
        .cardPanel(tint: isFromLists ? CardStyle.listsGreen : nil)
        .animation(Motion.press(reduced: reduceMotion), value: model.room.ticks)
    }

    private var tickColor: Color {
        isFromLists ? CardStyle.listsGreen : CardStyle.accent
    }

    private func row(_ index: Int, _ item: ChecklistCard.Item) -> some View {
        let done = isDone(index)
        return Button {
            guard let tick = tick(index) else {
                return
            }
            Task {
                await model.room.tick(tick, isDone: !done, in: conversation)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? tickColor : CardStyle.ink.opacity(0.3))
                    .contentTransition(.symbolEffect(.replace))
                Text(item.text)
                    .font(.subheadline)
                    .foregroundStyle(CardStyle.ink)
                    .strikethrough(done, color: CardStyle.ink.opacity(0.5))
                    .opacity(done ? 0.5 : 1)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(messageId == nil)
        .haptic(.selection, trigger: done)
        .accessibilityLabel(item.text)
        .accessibilityValue(done ? "Done" : "Not done")
        .accessibilityHint(done ? "Unticks it" : "Ticks it")
    }
}
