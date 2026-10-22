// The calendar mark (CalendarMark) as a small white page of the Calendar app's icon: the
// month in red capitals over the day's number, large.

import SwiftUI

struct CalendarMarkTile: View {
    let mark: CalendarMark

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: mark.month)
                .font(.caption2.weight(.heavy))
                .tracking(0.6)
                .foregroundStyle(.red)
            Text(verbatim: mark.day)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
        }
        .frame(minWidth: 46, minHeight: 50)
        .padding(.horizontal, 2)
        .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(CardStyle.accent.opacity(0.15))
        }
        .accessibilityHidden(true)
    }
}
