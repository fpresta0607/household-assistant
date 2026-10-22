// Connecting with a password, which only a connector with no OAuth asks for: the account's
// address, the password in a secure field, one line on where to make an app password for
// iCloud or the mail account, which take nothing else from another app, and Connect. For
// Switch account it signs in with the new account, and the gateway forgets the one it
// replaces only once the new one is linked.
//
// The password leaves the field only for the signed call to this phone's own gateway,
// which keeps it sealed. The field is emptied as it goes, and it is never kept, logged or
// shown again. The sheet closes once the gateway reads back Connected, and says why in one
// line when it will not.

import SwiftUI

struct ConnectorPasswordSheet: View {
    let connector: Connector
    /// The account this one replaces, for Switch account.
    var replacing: LinkedAccount? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    private enum Field {
        case username
        case password
    }

    /// Apple's page on app-specific passwords, the only kind iCloud takes from another app.
    private static let applePage = URL(string: "https://support.apple.com/en-us/102654")!

    var body: some View {
        let settings = model.assistantSettings
        let isSending = settings.isSigningIn(connector)
        let isApple = connector.id == "icloud"
        let assistant = model.assistantName
        NavigationStack {
            SettingsPage(replacing == nil ? "Connect \(connector.name)" : "Switch account") {
                SettingsGroup(
                    note: isApple
                        ? "Make an app-specific password at account.apple.com, in Sign-In and Security."
                        : connector.usesAppPassword
                            ? "Make an app password in your mail account's security settings."
                            : "Your \(connector.name) password goes only to \(assistant)'s gateway, which keeps it sealed.",
                    refusal: settings.refusal(for: [.connector(connector.id)])
                ) {
                    TextField(isApple ? "Apple Account email" : "Email address", text: $username)
                        .font(.body)
                        .foregroundStyle(Palette.text)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .username)
                        .onSubmit {
                            focused = .password
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                    SecureField(connector.usesAppPassword ? "App password" : "Password", text: $password)
                        .font(.body)
                        .foregroundStyle(Palette.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focused, equals: .password)
                        .onSubmit(connect)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                }
                if isApple {
                    Link(destination: Self.applePage) {
                        Label("Apple's page on app-specific passwords", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.semibold))
                    }
                    .tint(Palette.highlight)
                    .padding(.horizontal, 4)
                }
                // Glass with royal words and rim, never a royal fill, so not the bar's
                // confirmation button, which iOS fills.
                Button(action: connect) {
                    HStack(spacing: 8) {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSending ? "Connecting" : "Connect")
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
                .disabled(!isReady || isSending)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            focused = .username
        }
    }

    private var isReady: Bool {
        !cleaned(username).isEmpty && !cleaned(password).isEmpty
    }

    /// Without the spaces and line ends a paste brings: the gateway takes one line.
    private func cleaned(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard isReady, !model.assistantSettings.isSigningIn(connector) else {
            return
        }
        let credential = ConnectorCredential.password(username: cleaned(username), secret: SecretText(cleaned(password)))
        password = ""
        Task {
            await model.assistantSettings.connect(connector, with: credential, replacing: replacing)
            if model.assistantSettings.refusal == nil {
                dismiss()
            }
        }
    }
}
