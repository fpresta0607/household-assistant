// The day at a glance above the pins on Chats (CFO notes section 21c): the assistant's face
// in its gold ring and "Corey · Today", or Tonight in the evening, with that word the one
// small gold mark; then the day the way the Overlord asked for it on 22 October, clean
// rather than wordy: the calendar mark of the day, the month in three letters over the day's
// number, and beside it the next thing and two more at most, each in bold with its time
// (AgendaDayView); and the day's verse at the bottom, which opens in the Bible app. A tap
// anywhere else opens the whole day, with each thing's helping line. Absent when nothing is left to show. Each person's comes from
// their own assistant, kept on the phone so it shows offline too (TodayModel).
//
// Whole the first time each day. Once seen, as its person leaves Chats or the app with it on
// screen, or checked off with the tick in its corner, it is a slim banner at the top for the
// rest of the day: the assistant's face, the word Today and the next thing, which a tap
// opens back into the whole card.

import SwiftUI

struct TodayCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isDayOpen = false

    var body: some View {
        if let glance = model.today.glance {
            // One container, so the card turning into the banner is no leaving of Chats.
            VStack(spacing: 0) {
                if model.today.isFolded {
                    banner(glance)
                } else {
                    card(glance)
                }
            }
            .padding(.horizontal, 16)
            .transition(Motion.popTransition(reduced: reduceMotion))
            .onAppear {
                ChatTiming.todayShown()
            }
            .onDisappear {
                model.today.markSeen()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    model.today.markSeen()
                }
            }
            .sheet(isPresented: $isDayOpen) {
                TodayDaySheet()
            }
        }
    }

    private func card(_ glance: TodayGlance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Beside the day's button, not in it, so each is its own element.
            ZStack(alignment: .topTrailing) {
                Button {
                    isDayOpen = true
                } label: {
                    day(glance)
                }
                .buttonStyle(.plain)
                // One element for the whole day, which keeps the button's trait only when told.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(glance))
                .accessibilityHint("Shows the whole day")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("today.card")
                Button {
                    withAnimation(Motion.arrive(reduced: reduceMotion)) {
                        model.today.markSeen()
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // In the header's corner, out past the card's padding so it is a full target.
                .offset(x: 12, y: -12)
                .accessibilityLabel("Done for today")
                .accessibilityHint("Folds the card to a banner until tomorrow")
                .accessibilityIdentifier("today.done")
            }
            if let verse = glance.verse {
                Rectangle()
                    .fill(Palette.gold.opacity(0.35))
                    .frame(height: 1)
                TodayVerseRow(verse: verse)
            }
        }
        .padding(16)
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .transition(Motion.popTransition(reduced: reduceMotion))
    }

    /// The face, the day's word in gold and the next thing, on one line.
    private func banner(_ glance: TodayGlance) -> some View {
        Button {
            withAnimation(Motion.arrive(reduced: reduceMotion)) {
                model.today.open()
            }
        } label: {
            HStack(spacing: 10) {
                AssistantAvatar(emoji: model.identity?.emoji, photo: model.assistantPhoto, size: 22, ring: model.assistantRing)
                Text(heading(glance))
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(Palette.goldText)
                Text(verbatim: glance.next.map(sentence) ?? (glance.heading == .tonight ? "Nothing else tonight" : "Nothing else today"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .rainbowGlass(in: Capsule(), isInteractive: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(glance))
        .accessibilityHint("Shows the day's card")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("today.banner")
        .transition(Motion.popTransition(reduced: reduceMotion))
    }

    private func day(_ glance: TodayGlance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AssistantAvatar(emoji: model.identity?.emoji, photo: model.assistantPhoto, size: 28, ring: model.assistantRing)
                HStack(spacing: 0) {
                    Text("\(model.assistantName) · ")
                        .foregroundStyle(Palette.secondaryText)
                    Text(heading(glance))
                        .foregroundStyle(Palette.goldText)
                }
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.7)
                Spacer(minLength: 0)
            }
            if glance.next == nil {
                Text(glance.heading == .tonight ? "Nothing else tonight" : "Nothing else today")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                AgendaDayView(day: glance.agendaDay(at: Date(), calendar: .current))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func heading(_ glance: TodayGlance) -> String {
        glance.heading == .tonight ? "Tonight" : "Today"
    }

    /// "School drop off at 7:45", or with the day's name when it is another day's.
    private func sentence(_ line: TodayGlance.Line) -> String {
        guard let time = line.time else {
            return line.title
        }
        return Calendar.current.isDateInToday(line.start) ? "\(line.title) at \(time)" : "\(line.title), \(time)"
    }

    private func spoken(_ glance: TodayGlance) -> String {
        var words = ["\(model.assistantName), \(heading(glance))."]
        if let next = glance.next {
            words.append("Next, \(sentence(next)).")
            if let detail = next.detail {
                words.append(detail)
            }
        }
        for line in glance.more {
            words.append("Then \(line.title)\(line.time.map { " at \($0)" } ?? "").")
        }
        return words.joined(separator: " ")
    }
}
