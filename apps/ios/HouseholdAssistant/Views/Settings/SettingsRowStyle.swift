// A row that opens a page or does something when tapped: the whole row is the target,
// and it darkens a little under the finger, as a row in iOS Settings does.

import SwiftUI

struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.text.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SettingsRowStyle {
    static var settingsRow: SettingsRowStyle {
        SettingsRowStyle()
    }
}
