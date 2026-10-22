// The buyer's order, in the lists' mint: the day it arrives, large, then how far it has
// come as a line through its steps, and its masked number small at the foot. Drawn only
// in the buyer's own thread (RoomMarkdown leaves one in the family room out).

import SwiftUI

struct OrderCardView: View {
    let order: OrderCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbol: "shippingbox.fill", tint: CardStyle.listsGreen, kind: "Order", title: order.title, note: items)
            VStack(alignment: .leading, spacing: 1) {
                if let arriving, order.status != .delivered {
                    Text("Arriving")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CardStyle.secondaryInk)
                    Text(arriving)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(CardStyle.ink)
                } else {
                    Text(order.steps[order.reached - 1].label)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(CardStyle.ink)
                }
            }
            progress
            if let number = order.order {
                Text("Order \(number)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(CardStyle.secondaryInk)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPanel(tint: CardStyle.listsGreen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var items: String {
        order.items == 1 ? "1 item" : "\(order.items) items"
    }

    /// "Friday, October 16", the day on the phone's own calendar.
    private var arriving: String? {
        order.arriving
            .flatMap { Calendar.current.date(from: $0) }
            .map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
    }

    /// Each step a dot on one line, filled up to where the order is, with its name and,
    /// when an email dated it, its day beneath.
    private var progress: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(order.steps.enumerated()), id: \.offset) { index, step in
                VStack(spacing: 4) {
                    ZStack {
                        HStack(spacing: 0) {
                            segment(isShown: index > 0, isReached: index < order.reached)
                            segment(isShown: index < order.steps.count - 1, isReached: index + 1 < order.reached)
                        }
                        dot(index)
                    }
                    .frame(height: 16)
                    Text(step.label)
                        .font(.caption2.weight(index == order.reached - 1 ? .bold : .regular))
                        .foregroundStyle(index < order.reached ? CardStyle.ink : CardStyle.secondaryInk)
                        .multilineTextAlignment(.center)
                    if let at = step.at {
                        Text(at.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption2)
                            .foregroundStyle(CardStyle.secondaryInk)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Half the line between two dots.
    private func segment(isShown: Bool, isReached: Bool) -> some View {
        Rectangle()
            .fill(isShown ? (isReached ? CardStyle.listsGreen : CardStyle.ink.opacity(0.14)) : .clear)
            .frame(height: 3)
    }

    /// Filled where the order has been, with a soft halo on where it is now.
    @ViewBuilder
    private func dot(_ index: Int) -> some View {
        if index < order.reached {
            Circle()
                .fill(CardStyle.listsGreen)
                .frame(width: 12, height: 12)
                .background {
                    if index == order.reached - 1 {
                        Circle()
                            .fill(CardStyle.listsGreen.opacity(0.25))
                            .frame(width: 22, height: 22)
                    }
                }
        } else {
            Circle()
                .fill(.white)
                .frame(width: 12, height: 12)
                .overlay {
                    Circle()
                        .strokeBorder(CardStyle.ink.opacity(0.22), lineWidth: 2)
                }
        }
    }

    private var spoken: String {
        var parts = ["\(order.title), \(items)", order.steps[order.reached - 1].label]
        if let arriving, order.status != .delivered {
            parts.append("Arriving \(arriving)")
        }
        if let number = order.order {
            parts.append("Order \(number)")
        }
        return parts.joined(separator: ". ")
    }
}
