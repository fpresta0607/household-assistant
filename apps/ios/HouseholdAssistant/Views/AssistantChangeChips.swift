// What an assistant's answer changed, as small glass chips under its bubble: "Added Movie
// night, Fri 7:00 PM" by a royal calendar, "Reminder set, 3:45 PM" by a gold bell. Each chip
// is glass, its royal or gold only in the glyph. A tap opens what the chip names where the
// phone can: the event's day in Calendar, or the reminder as its card, which zooms out of
// its chip. The skill badge above the bubble names who answered; these name what changed.

import SwiftUI

struct AssistantChangeChips: View {
    let changes: [AssistantChange]

    @Environment(\.openURL) private var openURL
    @State private var reminder: ReminderCard?
    /// Which chip the reminder's card zooms out of.
    @State private var openedChip = 0
    @Namespace private var zoom

    var body: some View {
        ChipFlow(spacing: 8) {
            ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                chip(change, at: index)
            }
        }
        .padding(.top, 4)
        .sheet(isPresented: Binding(get: { reminder != nil }, set: { isShown in
            if !isShown {
                reminder = nil
            }
        })) {
            if let reminder {
                ReminderCardView(reminder: reminder)
                    .padding(24)
                    .presentationDetents([.height(150)])
                    .zoomTransition(from: openedChip, in: zoom)
            }
        }
    }

    @ViewBuilder
    private func chip(_ change: AssistantChange, at index: Int) -> some View {
        let words = change.words(now: Date(), calendar: .current)
        switch change.destination(calendar: .current) {
        case .calendar(let day):
            Button {
                openURL(day)
            } label: {
                label(change, words: words, isTappable: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Calendar on that day")
        case .reminder(let card):
            Button {
                openedChip = index
                reminder = card
            } label: {
                label(change, words: words, isTappable: true)
                    .zoomSource(index, in: zoom)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the reminder")
        case nil:
            label(change, words: words, isTappable: false)
        }
    }

    private func label(_ change: AssistantChange, words: String, isTappable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: change.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(glyph(change))
                .accessibilityHidden(true)
            Text(words)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 280, alignment: .leading)
        .rainbowGlass(in: Capsule(), isInteractive: isTappable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(words)
    }

    /// The calendar and the cart in royal, the reminder and the email in the assistant's gold.
    private func glyph(_ change: AssistantChange) -> Color {
        switch change.kind {
        case .event, .list:
            return Palette.highlight
        case .reminder, .message:
            return Palette.goldText
        }
    }
}
