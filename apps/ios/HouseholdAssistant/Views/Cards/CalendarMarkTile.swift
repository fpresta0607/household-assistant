// The calendar mark (CalendarMark) in the selected theme: the month over the day's number.

import SwiftUI

struct CalendarMarkTile: View {
    let mark: CalendarMark

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: mark.month)
                .font(.caption2.weight(.heavy))
                .tracking(0.6)
                .foregroundStyle(Palette.text)
            Text(verbatim: mark.day)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
        }
        .frame(minWidth: 46, minHeight: 50)
        .padding(.horizontal, 2)
        .background(CardStyle.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(CardStyle.accent.opacity(0.15))
        }
        .accessibilityHidden(true)
    }
}
