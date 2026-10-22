// One connector's own page, opened from Connectors. Under what the connector is for: its
// company's icon, its name, what it does and its switch, or why this gateway cannot have
// it. Then each account it is signed in with, by the provider's name for it, its address
// and when it was linked, with what the assistant can do with that account, Switch account
// and Disconnect. Then what the assistant can do with the connector itself.
//
// Disconnect asks for a yes first, and neither it nor Switch account is there for a
// sign-in set up on the assistant's computer, which only the box changes. Switch account
// signs in with another account, and the gateway forgets the old one only once the new
// one is linked, so it is how a Google account gog holds on the box gives way to the
// person's own, rather than a second account beside it. One that waits for a sign-in has
// Connect, which starts it right here, as its switch does. An older gateway counts its
// sign-ins and lists none, so they show as one count, led by the green dot, with
// Disconnect.
//
// The gateway lists only its own person's accounts, so each phone shows only its own side.

import SwiftUI

struct ConnectorPage: View {
    let connectorId: String

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var signingIn: ConnectorSignInRequest?
    @State private var isConfirmingDisconnect = false
    /// The account whose sign-in waits for a yes before it is forgotten, or nil for every
    /// sign-in an older gateway holds.
    @State private var disconnecting: LinkedAccount?

    /// The screenshot tests open it with a sign-in's sheet over it.
    init(connectorId: String, signingIn: ConnectorSignInRequest? = nil) {
        self.connectorId = connectorId
        _signingIn = State(initialValue: signingIn)
    }

    var body: some View {
        let settings = model.assistantSettings
        let assistant = model.assistantName
        if let connector = settings.current?.connectors.first(where: { $0.id == connectorId }) {
            SettingsPage(connector.name) {
                SettingsGroup(
                    connector.category.title,
                    note: note(for: connector, assistant: assistant),
                    refusal: settings.refusal(for: [.connector(connector.id)])
                ) {
                    SettingsRow(connector.name, subtitle: connector.summary) {
                        BrandTile(connector.icon, fallbackName: connector.name, size: 48)
                    } trailing: {
                        ConnectorSwitch(connector: connector, signingIn: $signingIn)
                    }
                    .opacity(connector.state == .unavailable ? 0.5 : 1)
                }
                accounts(of: connector, assistant: assistant)
                if !connector.capabilities.isEmpty {
                    SettingsGroup("What \(assistant) can do") {
                        ForEach(connector.capabilities, id: \.self) { capability in
                            AssistantAbility(text: capability)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }
            }
            .animation(Motion.flip(reduced: reduceMotion), value: settings.signingIn)
            .haptic(.success, trigger: connector.linkedAccounts.map(\.id)) { before, after in
                after.contains { !before.contains($0) }
            }
            .connectorSignIn($signingIn)
            .confirmationDialog(
                disconnecting.map { "Disconnect \($0.email ?? $0.name)?" } ?? "Disconnect \(connector.name)?",
                isPresented: $isConfirmingDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    let account = disconnecting
                    Task {
                        await settings.disconnect(connector, account: account)
                    }
                }
            } message: {
                Text("\(assistant)'s gateway forgets the sign-in, and \(assistant) stops reaching \(connector.name) through it.")
            }
        } else {
            SettingsPage("Connector") {
                SettingsGroup {
                    SettingsRow(settings.errorText ?? "Asking \(model.assistantName)'s gateway") {
                        if settings.errorText == nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    /// Each account it is signed in with, or Connect while it waits for a sign-in.
    @ViewBuilder
    private func accounts(of connector: Connector, assistant: String) -> some View {
        let settings = model.assistantSettings
        if !connector.linkedAccounts.isEmpty {
            SettingsGroup("Signed in") {
                ForEach(connector.linkedAccounts) { account in
                    LinkedAccountRow(
                        account: account,
                        icon: connector.icon,
                        provider: connector.name,
                        assistant: assistant,
                        isBusy: settings.isSigningIn(connector),
                        switchAccount: {
                            signingIn = ConnectorSignInRequest(connector: connector, replacing: account)
                        },
                        disconnect: {
                            disconnecting = account
                            isConfirmingDisconnect = true
                        }
                    )
                }
            }
        } else if let count = connector.connectedWords {
            SettingsGroup("Signed in") {
                SettingsRow(connector.name, subtitle: count, isConnected: true) {
                    BrandTile(connector.icon, fallbackName: connector.name, size: 40)
                } trailing: {
                    if settings.isSigningIn(connector) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Disconnect", role: .destructive) {
                            disconnecting = nil
                            isConfirmingDisconnect = true
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityLabel("Disconnect \(connector.name)")
                    }
                }
            }
        } else if connector.state == .available {
            // Glass with royal words and rim, never a royal fill.
            Button {
                signingIn = ConnectorSignInRequest(connector: connector)
            } label: {
                HStack(spacing: 8) {
                    if settings.isSigningIn(connector) {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Connect \(connector.name)")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glass)
            .foregroundStyle(Palette.highlight)
            .overlay {
                Capsule()
                    .strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .disabled(settings.isSigningIn(connector))
        }
    }

    private func note(for connector: Connector, assistant: String) -> String? {
        switch connector.state {
        case .connected:
            return "Switching it off takes it away from \(assistant) at once, on Telegram too."
        case .available:
            return connector.signInNeed.map { "\($0). Turning it on signs in with your own account." }
        case .unavailable:
            return connector.reason
        }
    }
}
