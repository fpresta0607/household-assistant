// PocketPiggies in the chat, in PocketPiggies' own look: the balance across the piggies,
// this month's budget on a rainbow meter, spending by category as bars, or a savings goal
// as a ring, with its numbers and titles in Space Grotesk.
//
// One that arrives in a live reply fills in: the meter runs up, the bars grow one by
// one and the ring pops into place. One already in the conversation is simply there,
// and with Reduce Motion nothing moves.

import Charts
import SwiftUI

struct PocketPiggiesCardView: View {
    let card: PocketPiggiesCard
    let isArriving: Bool

    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// How many steps of filling in have happened: the bars one at a time, or the meter
    /// and the ring in one.
    @State private var revealed: Int

    init(card: PocketPiggiesCard, isArriving: Bool) {
        self.card = card
        self.isArriving = isArriving
        _revealed = State(initialValue: isArriving ? 0 : Self.steps(of: card))
    }

    private static func steps(of card: PocketPiggiesCard) -> Int {
        if case .spending(_, let categories) = card {
            return categories.count
        }
        return 1
    }

    private var isFilled: Bool {
        revealed > 0
    }

    var body: some View {
        content
            .foregroundStyle(PocketPiggiesTheme.ink)
            .task {
                await fillIn()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case .balance(let total, let piggies):
            balance(total, piggies)
        case .budget(let month, let spent, let limit, let daysLeft):
            budget(month: month, spent: spent, limit: limit, daysLeft: daysLeft)
        case .spending(let title, let categories):
            spending(title: title, categories: categories)
        case .goal(let name, let saved, let target, let weekly):
            goal(name: name, saved: saved, target: target, weekly: weekly)
        }
    }

    // MARK: - The four cards

    private func balance(_ total: Double, _ piggies: [PocketPiggiesCard.Piggy]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            head("Balance")
            Text(CardNumber.money(total))
                .font(PocketPiggiesTheme.bold(.title))
                .monospacedDigit()
            if !piggies.isEmpty {
                Text("Across \(piggies.count) \(piggies.count == 1 ? "piggy" : "piggies")")
                    .font(.footnote)
                    .foregroundStyle(PocketPiggiesTheme.mutedInk)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(piggies.enumerated()), id: \.offset) { index, piggy in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(CardNumber.money(piggy.balance))
                                .font(PocketPiggiesTheme.bold(.subheadline))
                                .monospacedDigit()
                            Text(piggy.name)
                                .font(.caption2)
                                .foregroundStyle(PocketPiggiesTheme.mutedInk)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PocketPiggiesTheme.surface(index), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 8)
            }
        }
        .piggiesCard()
    }

    private func budget(month: String, spent: Double, limit: Double, daysLeft: Int?) -> some View {
        let progress = card.progress ?? 0
        var detail = "of \(CardNumber.money(limit)) spent"
        if let daysLeft {
            detail += " \u{00B7} \(daysLeft) \(daysLeft == 1 ? "day" : "days") left"
        }
        return VStack(alignment: .leading, spacing: 2) {
            label("\(month) budget")
            Text(CardNumber.money(spent))
                .font(PocketPiggiesTheme.bold(.title))
                .monospacedDigit()
            Text(detail)
                .font(.footnote)
                .foregroundStyle(PocketPiggiesTheme.mutedInk)
            Capsule()
                .fill(Color.black.opacity(0.08))
                .frame(height: 12)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(PocketPiggiesTheme.rainbowAcross)
                            .frame(width: proxy.size.width * (isFilled ? progress : 0))
                    }
                }
                .padding(.top, 8)
                .accessibilityElement()
                .accessibilityLabel("Spent")
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        }
        .piggiesCard()
        .overlay {
            // PocketPiggies' own rainbow rim in the light, and in the dark the gold rim the
            // rest of the glass takes, since the dark has no rainbow (CFO notes section 21).
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            if colorScheme == .dark {
                GlassRim(shape: shape)
            } else {
                shape.strokeBorder(PocketPiggiesTheme.rainbow, lineWidth: 2)
            }
        }
    }

    private func spending(title: String?, categories: [PocketPiggiesCard.Category]) -> some View {
        let largest = max(categories.map(\.amount).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            head(title ?? "Spending by category")
            Chart(Array(categories.enumerated()), id: \.offset) { index, category in
                BarMark(
                    x: .value("Amount", index < revealed ? category.amount : 0),
                    y: .value("Category", category.name)
                )
                .foregroundStyle(PocketPiggiesTheme.bar(index))
                .cornerRadius(5)
                .annotation(position: .trailing, spacing: 6) {
                    Text(CardNumber.money(category.amount))
                        .font(PocketPiggiesTheme.bold(.caption))
                        .monospacedDigit()
                        .foregroundStyle(PocketPiggiesTheme.ink)
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...(largest * 1.35))
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.caption)
                        .foregroundStyle(PocketPiggiesTheme.mutedInk)
                }
            }
            .frame(height: CGFloat(categories.count) * 26 + 6)
        }
        .piggiesCard()
    }

    private func goal(name: String, saved: Double, target: Double, weekly: Double?) -> some View {
        let progress = card.progress ?? 0
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.07), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(colors: PocketPiggiesTheme.rainbowStops, center: .center, startAngle: .zero, endAngle: .degrees(360 * max(progress, 0.01))),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(Int((progress * 100).rounded()))%")
                    .font(PocketPiggiesTheme.bold(.headline))
            }
            .frame(width: 92, height: 92)
            .scaleEffect(isFilled ? 1 : 0.7)
            .opacity(isFilled ? 1 : 0)
            .accessibilityElement()
            .accessibilityLabel("Saved")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            VStack(alignment: .leading, spacing: 2) {
                label("Savings goal")
                Text(name)
                    .font(PocketPiggiesTheme.bold(.title3))
                Text("\(CardNumber.money(saved)) of \(CardNumber.money(target))")
                    .font(.footnote)
                    .foregroundStyle(PocketPiggiesTheme.mutedInk)
                if let weekly {
                    Text("Saving \(CardNumber.money(weekly)) a week")
                        .font(.footnote)
                        .foregroundStyle(PocketPiggiesTheme.mutedInk)
                }
            }
        }
        .piggiesCard()
    }

    // MARK: - Pieces

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(PocketPiggiesTheme.medium(.caption2))
            .tracking(1.3)
            .foregroundStyle(PocketPiggiesTheme.mutedInk)
    }

    /// A card's label with the pig at the far end.
    private func head(_ text: String) -> some View {
        HStack {
            label(text)
            Spacer(minLength: 4)
            PiggyMark()
                .frame(width: 26, height: 26)
        }
    }

    private func fillIn() async {
        let steps = Self.steps(of: card)
        guard revealed < steps else {
            return
        }
        guard !reduceMotion else {
            revealed = steps
            return
        }
        for step in revealed..<steps {
            try? await Task.sleep(for: Motion.growStep)
            withAnimation(Motion.grow) {
                revealed = step + 1
            }
        }
    }
}
