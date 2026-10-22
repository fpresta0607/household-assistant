// Share my location, from the composer's plus: once, or live for 15 minutes, an hour or
// until the end of the day, as a glass menu over the bar. The chosen one turns while the
// phone finds where it is; the accent is only ever a glyph here, never a fill.

import SwiftUI

struct LocationShareMenu: View {
    /// The span being shared now, while the phone finds where it is.
    let sharing: MapShareSpan?
    let onPick: (MapShareSpan) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Share my location")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(MapShareSpan.allCases) { span in
                Button {
                    onPick(span)
                } label: {
                    HStack {
                        Text(span.title)
                            .font(.body.weight(sharing == span ? .semibold : .regular))
                            .foregroundStyle(Palette.text)
                        Spacer(minLength: 8)
                        if sharing == span {
                            ProgressView()
                                .tint(Palette.highlight)
                        } else if span == .once {
                            Image(systemName: "location.fill")
                                .foregroundStyle(Palette.highlight)
                        }
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sharing != nil)
                .accessibilityHint(span == .once ? "Shares where you are now as a map" : "Shares a map that moves with you")
            }
        }
        .padding(8)
        .frame(maxWidth: 280, alignment: .leading)
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
