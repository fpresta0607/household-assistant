// One day of a snapshot: its calendar mark, and beside it a row for each thing on it, the
// thing in bold and its time at the end. The Today card and each day of the agenda card.

import SwiftUI

struct AgendaDayView: View {
    let day: AgendaCard.Day
    /// The words' colours: the app's own on the Today card, the bubble's in a card.
    var ink: Color = Palette.text
    var secondaryInk: Color = Palette.secondaryText

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CalendarMarkTile(mark: day.mark)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(day.events.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // As written: the assistant's words, never read as Markdown.
                        Text(verbatim: event.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ink)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(verbatim: event.time ?? "All day")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// "October 22: School pickup, 3:15 PM. Soccer, 5:30 PM."
    private var spoken: String {
        let month = Calendar(identifier: .gregorian).monthSymbols[(CalendarMark.months.firstIndex(of: day.mark.month) ?? 0)]
        let things = day.events.map { "\($0.title), \($0.time ?? "all day")." }.joined(separator: " ")
        return "\(month) \(day.mark.day): \(things)"
    }
}
