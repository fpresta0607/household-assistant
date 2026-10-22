// A reminder the assistant set: a bell in orange, what it will say, and when.

import SwiftUI

struct ReminderCardView: View {
    let reminder: ReminderCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "bell.fill", tint: CardStyle.orange, kind: "Reminder", title: reminder.text)
            Text(when)
                .font(.subheadline)
                .foregroundStyle(CardStyle.ink.opacity(0.78))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPanel()
        .accessibilityElement(children: .combine)
    }

    /// "Saturday, October 17 at 5:30 PM", in this phone's time zone.
    private var when: String {
        reminder.at.formatted(.dateTime.weekday(.wide).month(.wide).day()) + " at " + reminder.at.formatted(date: .omitted, time: .shortened)
    }
}
