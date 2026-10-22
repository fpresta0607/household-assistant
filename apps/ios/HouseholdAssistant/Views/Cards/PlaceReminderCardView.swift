// A reminder by place: what it says, the map round the place with the circle that counts
// as being there in gold, and when it goes off. Then what this phone may do with
// it (PlaceReminderState): Set its person's own, which asks iOS for Always the first time;
// say yes or no when another assistant asks to watch them; or see whether the other
// person said yes to this phone's assistant. Gold is the circle's rim and the pin, and the
// buttons are glass with the accent at their rim.

import MapKit
import SwiftUI

struct PlaceReminderCardView: View {
    let card: PlaceReminderCard
    /// Nil until the gateway has kept the message, and nothing can be set before then.
    let messageId: String?
    let author: String

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isWorking = false

    private var state: PlaceReminderState? {
        guard let me = model.room.me else {
            return nil
        }
        let id = messageId ?? ""
        return PlaceReminderState(
            card: card,
            author: author,
            me: me,
            participants: model.room.participants,
            answers: model.room.family.placeAnswers[id] ?? [:],
            isWatching: model.placeReminders.isWatching(id),
            hasFired: model.placeReminders.hasFired(id)
        )
    }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "location.circle.fill", tint: CardStyle.orange, kind: "Reminder by place", title: card.text)
            MapSnapshot(region: MKCoordinateRegion(around: card.place.center, metres: max(700, card.place.radius * 6)), height: 108) { projection in
                let center = projection.point(card.place.center)
                let across = projection.span(metres: card.place.radius, at: card.place.center) * 2
                Fence()
                    .frame(width: across, height: across)
                    .position(center)
                PlacePin(label: card.place.label)
                    .position(center)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(whenWords(state))
                .font(.subheadline)
                .foregroundStyle(CardStyle.ink.opacity(0.78))
            if let state, messageId != nil {
                actions(state)
            }
            if let messageId, let refusal = model.room.placeRefusals[messageId] {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPanel()
        .disabled(isWorking)
        .animation(Motion.press(reduced: reduceMotion), value: state)
    }

    /// "When you arrive at home", "When Gia leaves work".
    private func whenWords(_ state: PlaceReminderState?) -> String {
        let place = card.place.label
        switch state {
        case .waitingFor(let name)?, .theySaidYes(let name)?, .theySaidNo(let name)?, .theirs(let name)?:
            return card.when == .arrive ? "When \(name) arrives at \(place)" : "When \(name) leaves \(place)"
        default:
            return card.when == .arrive ? "When you arrive at \(place)" : "When you leave \(place)"
        }
    }

    @ViewBuilder
    private func actions(_ state: PlaceReminderState) -> some View {
        switch state {
        case .readyToSet:
            accentButton("Set", systemImage: "bell.badge") {
                await model.setPlaceReminder(card, in: messageId ?? "")
            }
            .accessibilityHint("This iPhone watches the place, even with the app closed, and reminds you there")
        case .watching:
            mark("Set on this iPhone", systemImage: "checkmark", tint: CardStyle.accent)
        case .done:
            mark("Done", systemImage: "checkmark.circle", tint: CardStyle.secondaryInk)
        case .askingYou(let asker):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(asker) asks to tell \(model.otherPersonName). Only this iPhone watches the place, and only once you say yes.")
                    .font(.footnote)
                    .foregroundStyle(CardStyle.secondaryInk)
                HStack(spacing: 8) {
                    Button {
                        answer(.no)
                    } label: {
                        Text("Not now")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(CardStyle.ink)
                    accentButton("Allow", systemImage: "checkmark") {
                        await model.answerPlaceReminder(card, in: messageId ?? "", with: .yes)
                    }
                }
            }
        case .youSaidYes(let asker):
            HStack {
                mark("You said yes. \(asker) hears when it happens.", systemImage: "checkmark", tint: CardStyle.accent)
                Spacer(minLength: 4)
                Button("Stop") {
                    answer(.no)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(CardStyle.accent)
            }
        case .youSaidNo:
            mark("You said no", systemImage: "xmark", tint: CardStyle.secondaryInk)
        case .waitingFor(let name):
            chip("Waiting for \(name)'s OK", systemImage: "hourglass")
        case .theySaidYes(let name):
            chip("\(name) said yes", systemImage: "checkmark")
        case .theySaidNo(let name):
            chip("\(name) said no", systemImage: "xmark")
        case .theirs(let name):
            mark("For \(name)", systemImage: "person.fill", tint: CardStyle.secondaryInk)
        }
    }

    private func answer(_ answer: PlaceAnswer) {
        isWorking = true
        Task {
            await model.answerPlaceReminder(card, in: messageId ?? "", with: answer)
            isWorking = false
        }
    }

    /// Glass, with the accent as its rim and its bold words, never its fill.
    private func accentButton(_ title: String, systemImage: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            isWorking = true
            Task {
                await action()
                isWorking = false
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.glass)
        .foregroundStyle(CardStyle.accent)
        .overlay {
            Capsule()
                .strokeBorder(CardStyle.accent.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func mark(_ words: String, systemImage: String, tint: Color) -> some View {
        Label(words, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
    }

    /// A white chip with a gold rim and a gold glyph: the other person's answer, or none yet.
    private func chip(_ words: String, systemImage: String) -> some View {
        Label(words, systemImage: systemImage)
            .font(.footnote.weight(.bold))
            .foregroundStyle(CardStyle.ink)
            .labelStyle(GoldGlyph())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(CardStyle.gold.opacity(0.7), lineWidth: 1)
            }
    }
}

/// The circle round a place that counts as being there: a dashed gold rim over the faintest
/// wash, holding still, so the card costs nothing while it sits in the thread.
private struct Fence: View {
    var body: some View {
        let circle = Circle()
        circle
            .fill(Palette.gold.opacity(0.12))
            .overlay {
                circle.strokeBorder(Palette.gold, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
    }
}

/// A label whose glyph is gold and whose words keep their own colour.
private struct GoldGlyph: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .foregroundStyle(CardStyle.goldInk)
            configuration.title
        }
    }
}
