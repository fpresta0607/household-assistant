// Something on a day, with Add to Calendar. The button turns into a confirmation once the
// event is on the calendar, and says what went wrong when it could not be added. One the
// calendar skill read wears the calendar's royal, with the day on a little calendar page.

import SwiftUI

struct EventCardView: View {
    let event: EventCard
    let isFromCalendar: Bool

    @Environment(\.reducesMotion) private var reduceMotion
    @State private var state = AddState.ready

    private enum AddState: Equatable {
        case ready, adding, added
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isFromCalendar {
                HStack(spacing: 12) {
                    DateTile(date: event.start)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(CardStyle.ink)
                        Text(event.details(isDayShown: false))
                            .font(.subheadline)
                            .foregroundStyle(CardStyle.ink.opacity(0.78))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(event.title), \(event.details(isDayShown: true))")
            } else {
                CardHeader(symbol: "calendar", tint: CardStyle.sky, kind: "Event", title: event.title)
                Text(event.details(isDayShown: true))
                    .font(.subheadline)
                    .foregroundStyle(CardStyle.ink.opacity(0.78))
            }
            button
            if case .failed(let reason) = state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .cardPanel(tint: isFromCalendar ? CardStyle.accent : nil)
        .animation(Motion.press(reduced: reduceMotion), value: state)
    }

    @ViewBuilder
    private var button: some View {
        if state == .added {
            Label("Added to Calendar", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CardStyle.accent)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(CardStyle.accent.opacity(0.1), in: Capsule())
                .transition(.opacity)
        } else {
            Button {
                Task {
                    await add()
                }
            } label: {
                Text(state == .adding ? "Adding" : "Add to Calendar")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .accentGlass(CardStyle.accent)
            .disabled(state == .adding)
        }
    }

    private func add() async {
        state = .adding
        do {
            try await CalendarWriter.add(event)
            state = .added
        } catch CalendarWriter.Failure.notAllowed {
            state = .failed("Steward AI may not add to your calendar. You can allow it in Settings.")
        } catch {
            state = .failed("The event could not be added to your calendar.")
        }
    }
}
