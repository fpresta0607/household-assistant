// What this phone's assistant can reach. First what works on this iPhone, Contacts, which
// never touches the gateway. Then every connector its gateway has, the connected ones on top,
// then the ones waiting for their person's sign-in. Each has its company's icon and a switch,
// and opens a page of its own with its accounts and what the assistant can do with it.
//
// Turning on one that waits for a sign-in starts it right here, with the person's own
// account. The gateway lists only its own person's side, Franco's with Corey and Gia's
// with Denise, so this shows what it gets and nothing else.

import SwiftUI

struct ConnectorsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    /// The sign-in a switch asked for, while it starts.
    @State private var signingIn: ConnectorSignInRequest?

    /// The screenshot tests open it with an app password's or a token's sheet over it.
    init(signingIn: ConnectorSignInRequest? = nil) {
        _signingIn = State(initialValue: signingIn)
    }

    var body: some View {
        let settings = model.assistantSettings
        let name = model.assistantName
        SettingsPage("Connectors") {
            SettingsGroup("On this iPhone", note: "Contacts stays on this iPhone. Nothing from it goes to \(name)'s gateway.") {
                ContactsConnectorRow()
            }
            if settings.current == nil {
                SettingsGroup {
                    SettingsRow(settings.errorText ?? "Asking \(model.assistantName)'s gateway") {
                        if settings.errorText == nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            } else {
                ForEach(ConnectorState.allCases, id: \.self) { state in
                    let connectors = settings.connectors(state)
                    if !connectors.isEmpty {
                        SettingsGroup(
                            state == .connected ? "On \(name)'s gateway" : state.title,
                            note: note(for: state, assistant: name),
                            refusal: settings.refusal(for: connectors.map { SettingsField.connector($0.id) })
                        ) {
                            ForEach(connectors) { connector in
                                ConnectorRow(connector: connector, signingIn: $signingIn)
                            }
                        }
                    }
                }
                .animation(Motion.flip(reduced: reduceMotion), value: settings.pending)
                .animation(Motion.flip(reduced: reduceMotion), value: settings.signingIn)
            }
        }
        .connectorSignIn($signingIn)
        .haptic(.success, trigger: settings.connectors(.connected).count) { before, after in
            after > before
        }
        .task(id: model.connection.state == .connected) {
            if model.connection.state == .connected {
                await settings.load()
            }
        }
    }

    private func note(for state: ConnectorState, assistant: String) -> String? {
        switch state {
        case .connected:
            return "Tap one for its accounts and what \(assistant) can do with it. Switching one off takes it away from \(assistant) at once."
        case .available:
            return "Turning one on signs in with your own account."
        case .unavailable:
            return nil
        }
    }
}
