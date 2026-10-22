// The day as a page of the Calendar app's icon shows it: the weekday in red over the date.
// On an event the calendar read, and on a drafted text that carries an event.

import SwiftUI

struct DateTile: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.red)
            Text(date.formatted(.dateTime.day()))
                .font(.headline.weight(.bold))
                .foregroundStyle(Palette.ink)
        }
        .frame(minWidth: 38, minHeight: 40)
        .padding(.horizontal, 2)
        .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CardStyle.accent.opacity(0.15))
        }
        .accessibilityHidden(true)
    }
}
