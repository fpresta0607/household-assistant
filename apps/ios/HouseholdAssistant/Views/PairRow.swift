// The Corey & Denise group's row on Chats, under the two pins: both assistants' faces, the
// group's name over what they last did, and when, on glass like the Today card. It shows
// once the two assistants' line has any step, and opens the group (PairView).

import SwiftUI

struct PairRow: View {
    let onOpen: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let latest = model.pairLine.entries.last
        let words = latest?.words(names: model.room.names) ?? "How \(model.assistantName) and \(model.otherAssistantName ?? "the other assistant") coordinate"
        Button(action: onOpen) {
            HStack(spacing: 12) {
                PairFaces(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.pairName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(verbatim: words)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let latest {
                    Text(verbatim: when(latest.event.takenAt))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                }
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), isInteractive: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.pairName). \(words)")
        .accessibilityHint("Shows what the two assistants passed to each other")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("pair.row")
    }

    /// The time today, as Messages lists a conversation, and the day before that.
    private func when(_ date: Date) -> String {
        let divider = MessageTime.divider(for: date)
        return MessageTime.span(of: date, now: Date(), calendar: .current) == .today ? divider.time : divider.day
    }
}
