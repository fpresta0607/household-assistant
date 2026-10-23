// A table laid out natively with a Grid: a small capitalised header, a hairline between
// rows, numbers right-aligned in tabular figures. A table too wide for the bubble scrolls
// sideways rather than squeezing its words. Rows still arriving fade in one by one, each
// taking its height at once.

import SwiftUI

struct TableCardView: View {
    let table: TableCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = table.title {
                Text(title)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(CardStyle.ink.opacity(0.75))
                    .accessibilityAddTraits(.isHeader)
            }
            ViewThatFits(in: .horizontal) {
                grid
                ScrollView(.horizontal, showsIndicators: false) {
                    grid
                }
                .accessibilityIdentifier("card.table-scroll")
            }
            .cardPanel()
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { column, name in
                    Text(name.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.4)
                        .foregroundStyle(CardStyle.secondaryInk)
                        .gridColumnAlignment(horizontal(column))
                        .padding(.vertical, 8)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                Divider()
                    .overlay(CardStyle.hairline)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inline(cell))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(CardStyle.ink)
                            .padding(.vertical, 8)
                    }
                }
                .transition(Motion.rowTransition)
            }
        }
        .padding(.horizontal, 12)
    }

    private func horizontal(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    /// A cell's own emphasis, links and code, as a Markdown table writes them.
    private static func inline(_ cell: String) -> AttributedString {
        (try? AttributedString(markdown: cell, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cell)
    }
}
