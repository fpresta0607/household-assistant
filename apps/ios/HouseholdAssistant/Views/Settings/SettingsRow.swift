// One row of a Settings group: an optional icon, the title with a line under it, and
// whatever sits at the end, a value, a switch, a spinner or a chevron. Flush with the
// group's edge, at least as tall as a finger. When what the row stands for is connected,
// the green dot leads the line under the title, with no word for it.

import SwiftUI

struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let isConnected: Bool
    let leading: Leading
    let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        isConnected: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isConnected = isConnected
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Palette.text)
                if isConnected || subtitle != nil {
                    // The dot sits on the first line's baseline, level with its letters.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if isConnected {
                            StatusDot()
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Leading == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}
