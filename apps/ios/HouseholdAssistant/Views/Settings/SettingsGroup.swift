// A group of Settings rows: an optional label over it, the rows flush on one raised
// surface with separators that run its full width, then why a change was refused, and a
// quiet note. No row is indented.

import SwiftUI

struct SettingsGroup<Rows: View>: View {
    let label: String?
    let note: String?
    let refusal: String?
    let rows: Rows

    init(_ label: String? = nil, note: String? = nil, refusal: String? = nil, @ViewBuilder rows: () -> Rows) {
        self.label = label
        self.note = note
        self.refusal = refusal
        self.rows = rows()
    }

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            Group(subviews: rows) { subviews in
                VStack(spacing: 0) {
                    ForEach(subviews) { row in
                        if row.id != subviews.first?.id {
                            Divider()
                        }
                        row
                    }
                }
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
        .animation(Motion.flip(reduced: reduceMotion), value: refusal)
    }
}
