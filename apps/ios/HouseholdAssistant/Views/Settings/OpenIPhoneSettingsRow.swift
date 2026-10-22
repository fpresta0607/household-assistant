// The row under a setting only iOS can change: it opens Steward AI's own page in the
// iPhone's Settings, and the page it sits on reads the setting again when the app comes
// back (Permissions).

import SwiftUI
import UIKit

struct OpenIPhoneSettingsRow: View {
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            SettingsRow("Change in iPhone Settings") {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(Palette.highlight)
            }
        }
        .buttonStyle(.settingsRow)
    }
}
