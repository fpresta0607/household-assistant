// An agenda card: a day or a week at a glance, each day its calendar mark beside a row for
// each thing on it (AgendaDayView), under the card's title when it has one.

import SwiftUI

struct AgendaCardView: View {
    let agenda: AgendaCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = agenda.title {
                Text(verbatim: title)
                    .font(.headline)
                    .foregroundStyle(CardStyle.ink)
            }
            ForEach(Array(agenda.days.enumerated()), id: \.offset) { index, day in
                if index > 0 {
                    Divider()
                }
                AgendaDayView(day: day, ink: CardStyle.ink, secondaryInk: CardStyle.secondaryInk)
            }
        }
        .padding(12)
        .cardPanel(tint: CardStyle.accent)
    }
}
