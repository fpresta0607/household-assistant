// The Corey & Denise group, opened from its row on Chats or from the marker in the family
// room: every step the two assistants took on their direct line, the oldest at the top and
// the newest at the bottom, as a chat reads, with each day's name over its first line. Each
// step is one short line (PairEntryRow), and a burst of rows logged together is one.
//
// It is read-only, with no composer: the assistants write here and both parents watch. New
// steps arrive live, and older ones load as the person scrolls up to them, the way the
// thread's do, with what is on screen staying where it is.

import SwiftUI

struct PairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let entries = model.pairLine.entries
        ZStack {
            ChatBackgroundView(choice: .rainbow)
            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "arrow.left.arrow.right",
                    description: Text(verbatim: "When \(model.pairName) pass something to each other, it shows here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if model.pairLine.hasOlder {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                // Again each time a page lands with the top still in view.
                                .task(id: model.pairLine.events.first?.id) {
                                    await model.pairLine.loadOlder()
                                }
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if isFirstOfDay(index, in: entries) {
                                dayHeading(entry.event.takenAt)
                            }
                            PairEntryRow(entry: entry)
                                .transition(Motion.rowTransition)
                        }
                        Text(verbatim: "Only \(model.assistantName) and \(model.otherAssistantName ?? "the other assistant") write here.")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .animation(Motion.arrive(reduced: reduceMotion), value: entries.last?.id)
                }
                // Opens at the newest step, and a page landing above keeps what is on screen.
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
            }
        }
        .navigationTitle(model.pairName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                header
            }
        }
    }

    /// Both faces over the group's name in a glass pill, as a room's header shows its own,
    /// with no page to open.
    private var header: some View {
        VStack(spacing: 1) {
            PairFaces(size: 26)
            Text(verbatim: model.pairName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .rainbowGlass(in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func isFirstOfDay(_ index: Int, in entries: [PairEntry]) -> Bool {
        index == 0 || !Calendar.current.isDate(entries[index].event.takenAt, inSameDayAs: entries[index - 1].event.takenAt)
    }

    private func dayHeading(_ date: Date) -> some View {
        Text(verbatim: MessageTime.divider(for: date).day)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
