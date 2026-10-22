// The day's verse at the foot of the Today card and of the whole day: its words, its
// reference in gold, and Open, which takes it to the Bible app at that passage.

import SwiftUI

struct TodayVerseRow: View {
    let verse: TodayCard.Verse

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\u{201C}\(verse.text)\u{201D}")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: verse.reference)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.goldText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let link = verse.link {
                Button {
                    openURL(link)
                } label: {
                    Text("Open \u{203A}")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.goldText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(verse.reference) in the Bible app")
                .accessibilityIdentifier("today.verse.open")
            }
        }
    }
}
