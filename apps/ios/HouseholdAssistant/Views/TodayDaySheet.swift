// The whole day the Today card is a glance at, opened by a tap on it: everything the
// assistant put on it, the soonest first, what has gone by dimmed, each with the line that
// helps with it, and the day's verse at the foot.

import SwiftUI

struct TodayDaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(model.today.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: line.time ?? "All day")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: line.title)
                                    .foregroundStyle(Palette.text)
                                if let detail = line.detail {
                                    Text(verbatim: detail)
                                        .font(.subheadline)
                                        .foregroundStyle(Palette.secondaryText)
                                }
                            }
                        }
                        .opacity(line.isPast ? 0.45 : 1)
                        .accessibilityElement(children: .combine)
                    }
                }
                if let verse = model.today.glance?.verse {
                    Section {
                        TodayVerseRow(verse: verse)
                    }
                }
            }
            .accessibilityIdentifier("today.day")
            .navigationTitle(model.today.glance?.heading == .tonight ? "Tonight" : "Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
