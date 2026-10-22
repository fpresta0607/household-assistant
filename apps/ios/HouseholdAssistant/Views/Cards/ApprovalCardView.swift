// A step of the assistant's run that waits for this phone's person to say yes: what it
// would do, with Deny and Approve, and once answered, a confirmation in their place.
// The answer is signed by this phone and shows at once; one the gateway refuses comes
// back with why. A gold edge along its top says the assistant is the one asking.

import SwiftUI

struct ApprovalCardView: View {
    let message: RoomMessage
    let approval: RoomApproval

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    private var outcome: RoomApproval.Outcome? {
        model.room.approvalOutcome(of: message.id)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CardStyle.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "hand.raised.fill", tint: CardStyle.goldInk, kind: "Needs your OK", title: approval.title)
            if let detail = approval.detail {
                Text(detail)
                    .font(approval.isCommand ? .system(.footnote, design: .monospaced) : .subheadline)
                    .foregroundStyle(CardStyle.ink.opacity(0.78))
                    .lineLimit(8)
            }
            answers
                .padding(.top, 2)
            if let refusal = model.room.approvalRefusals[message.id] {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .cardPanel()
        .overlay {
            // Only the top of a gold rim, so it reads as an edge that follows the corners.
            shape.strokeBorder(CardStyle.gold, lineWidth: 4)
                .mask(alignment: .top) {
                    Rectangle().frame(height: 9)
                }
                .allowsHitTesting(false)
        }
        .animation(Motion.press(reduced: reduceMotion), value: outcome)
        .haptic(.success, trigger: outcome) { _, now in
            now == .approved
        }
    }

    /// Deny and Approve, of those the card offers, until it is answered; then what became of it.
    @ViewBuilder
    private var answers: some View {
        if let outcome {
            Label(outcome.words, systemImage: outcome.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(outcome == .approved ? CardStyle.accent : CardStyle.secondaryInk)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background((outcome == .approved ? CardStyle.accent : CardStyle.ink).opacity(0.1), in: Capsule())
                .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                if approval.decisions.contains(.deny) {
                    Button {
                        answer(.deny)
                    } label: {
                        Text("Deny")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.glass)
                    .tint(CardStyle.ink)
                    .accessibilityHint("Tells \(model.assistantName) not to")
                }
                if approval.decisions.contains(.approve) {
                    Button {
                        answer(.approve)
                    } label: {
                        Text("Approve")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .accentGlass(CardStyle.accent)
                    .accessibilityHint("Lets \(model.assistantName) go ahead, this once")
                }
            }
            .transition(.opacity)
        }
    }

    private func answer(_ decision: RoomApproval.Decision) {
        Task {
            await model.room.answer(message, with: decision)
        }
    }
}

private extension RoomApproval.Outcome {
    var words: String {
        switch self {
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .expired: return "No longer waiting"
        }
    }

    var symbol: String {
        switch self {
        case .approved: return "checkmark"
        case .denied: return "xmark"
        case .expired: return "clock"
        }
    }
}
