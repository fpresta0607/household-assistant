// Contacts in Connectors, in the group of what works on this iPhone rather than on the
// gateway: its grey tile, its name, the line under it, led by the green dot once it is on
// and iOS allows it, and its switch. The row opens its own page, and the switch sits beside
// the row rather than inside it, so a tap on the switch only ever flips it.

import SwiftUI

struct ContactsConnectorRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connector = model.contactsConnector
        HStack(spacing: 0) {
            NavigationLink {
                ContactsConnectorPage()
            } label: {
                SettingsRow("Contacts", subtitle: connector.line, isConnected: connector.isConnected) {
                    ContactsTile(size: 40)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.settingsRow)
            .accessibilityHint("Opens who you share and what \(model.assistantName) can do")
            ContactsSwitch()
                .padding(.trailing, 16)
        }
    }
}
