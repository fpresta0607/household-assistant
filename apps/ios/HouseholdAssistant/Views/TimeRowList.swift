// A list of times in an assistant's reply (Model/TimeRows.swift) as tidy rows: the time in
// a small white chip edged in gold, the words beside it on the same line. In a reply
// still arriving each row fades in as its line ends, taking its height at once.

import SwiftUI

struct TimeRowList: View {
    let rows: [TimeRows.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    chip(row.time)
                    Text(words(row.words))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .transition(Motion.rowTransition)
            }
        }
    }

    private func chip(_ time: String) -> some View {
        Text(time)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 64)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Palette.gold.opacity(0.55), lineWidth: 1)
            }
    }

    /// The words with their bold, italics and links, or as written if they are not Markdown.
    private func words(_ markdown: String) -> AttributedString {
        let inline = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: inline)) ?? AttributedString(markdown)
    }
}
