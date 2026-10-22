// A connector's switch, in Connectors and on its page. Once connected it turns the
// connector on or off for the assistant: it flips at once on a spring, shows a spinner
// while the gateway makes the change, and springs back with the gateway's reason when it
// will not. While the connector waits for its person's sign-in it shows off, and turning
// it on starts that sign-in right here. One this gateway cannot have stays off and still.
//
// The system's own green, as the approved Settings page shows: royal is never a fill.

import SwiftUI

struct ConnectorSwitch: View {
    let connector: Connector
    /// Where turning on one that waits for a sign-in asks for it.
    @Binding var signingIn: ConnectorSignInRequest?

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let settings = model.assistantSettings
        HStack(spacing: 8) {
            if settings.isPending(.connector(connector.id)) || settings.isSigningIn(connector) {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle(connector.name, isOn: isOn.animation(Motion.flip(reduced: reduceMotion)))
                .labelsHidden()
                .disabled(connector.state == .unavailable)
        }
    }

    private var isOn: Binding<Bool> {
        let settings = model.assistantSettings
        let connector = connector
        let signingIn = $signingIn
        return Binding(
            get: { settings.isOn(connector) },
            set: { isOn in
                switch connector.state {
                case .connected:
                    Task {
                        await settings.change(.connector(connector.id), to: isOn ? "on" : "off")
                    }
                case .available:
                    if isOn {
                        signingIn.wrappedValue = ConnectorSignInRequest(connector: connector)
                    }
                case .unavailable:
                    break
                }
            }
        )
    }
}
