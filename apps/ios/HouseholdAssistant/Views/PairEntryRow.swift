// One line of the Corey & Denise group: the face of the assistant who took the step, its
// plain words, a quieter line under them where one helps, and its time. No bubble, since
// nobody here is talking to the person reading. A tap shows a line cut short whole.

import SwiftUI

struct PairEntryRow: View {
    let entry: PairEntry

    @Environment(AppModel.self) private var model
    @State private var isWhole = false

    var body: some View {
        let words = entry.words(names: model.room.names)
        let time = entry.event.takenAt.formatted(date: .omitted, time: .shortened)
        Button {
            isWhole.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ParticipantAvatar(participant: model.room.participant(entry.event.by), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    // As written: the assistants' words, never read as Markdown.
                    Text(verbatim: words)
                        .font(.subheadline)
                        .foregroundStyle(Palette.text)
                        .lineLimit(isWhole ? nil : 2)
                    if let detail = entry.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(isWhole ? nil : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: time)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.top, 2)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([words, entry.detail, time].compactMap { $0 }.joined(separator: ". "))
    }
}
