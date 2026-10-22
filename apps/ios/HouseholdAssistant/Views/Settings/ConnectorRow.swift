// One connector in Connectors: its company's icon, its name, the line under it, led by the
// green dot once it is connected, and its switch. The row opens the connector's own page,
// and the switch sits beside the row rather than inside it, so a tap on the switch only
// ever flips it. One this gateway cannot have is dimmed, with the gateway's reason as its
// line.

import SwiftUI

struct ConnectorRow: View {
    let connector: Connector
    @Binding var signingIn: ConnectorSignInRequest?

    var body: some View {
        HStack(spacing: 0) {
            NavigationLink {
                ConnectorPage(connectorId: connector.id)
            } label: {
                SettingsRow(connector.name, subtitle: connector.line, isConnected: connector.isConnected) {
                    BrandTile(connector.icon, fallbackName: connector.name, size: 40)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.settingsRow)
            .accessibilityHint("Opens its accounts and what it can do")
            ConnectorSwitch(connector: connector, signingIn: $signingIn)
                .padding(.trailing, 16)
        }
        .opacity(connector.state == .unavailable ? 0.5 : 1)
    }
}
