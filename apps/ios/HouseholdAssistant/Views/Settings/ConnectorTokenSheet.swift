// Connecting with a token made at the provider, which only a connector with no OAuth on its
// gateway asks for, as Notion until the household's public Notion connection is set up:
// one secure field to paste it into, a line on where it is made with a link there, and
// Connect. For Switch account the gateway forgets the account it replaces only once the
// new one is linked.
//
// The token leaves the field only for the signed call to this phone's own gateway, which
// checks it with the provider and keeps it sealed. The field is emptied as it goes, and it
// is never kept, logged or shown again. The sheet closes once the gateway reads back
// Connected, and says why in one line when it will not.

import SwiftUI

struct ConnectorTokenSheet: View {
    let connector: Connector
    /// The account this one replaces, for Switch account.
    var replacing: LinkedAccount? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @FocusState private var isFocused: Bool

    /// Where Notion's internal integrations are made, each with the secret pasted here.
    private static let notionPage = URL(string: "https://www.notion.so/profile/integrations")!

    var body: some View {
        let settings = model.assistantSettings
        let isSending = settings.isSigningIn(connector)
        let isNotion = connector.id == "notion"
        let assistant = model.assistantName
        NavigationStack {
            SettingsPage(replacing == nil ? "Connect \(connector.name)" : "Switch account") {
                SettingsGroup(
                    note: isNotion
                        ? "Make an internal integration in Notion, give it the pages \(assistant) may use, and paste its secret here."
                        : "Make a token in your \(connector.name) account's settings and paste it here.",
                    refusal: settings.refusal(for: [.connector(connector.id)])
                ) {
                    SecureField("\(connector.name) token", text: $token)
                        .font(.body)
                        .foregroundStyle(Palette.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isFocused)
                        .onSubmit(connect)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                }
                if isNotion {
                    Link(destination: Self.notionPage) {
                        Label("Notion's integrations page", systemImage: "arrow.up.forward.square")
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
                .disabled(cleaned.isEmpty || isSending)
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
            isFocused = true
        }
    }

    /// Without the spaces and line ends a paste brings: the gateway takes one line.
    private var cleaned: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard !cleaned.isEmpty, !model.assistantSettings.isSigningIn(connector) else {
            return
        }
        let credential = ConnectorCredential.token(SecretText(cleaned))
        token = ""
        Task {
            await model.assistantSettings.connect(connector, with: credential, replacing: replacing)
            if model.assistantSettings.refusal == nil {
                dismiss()
            }
        }
    }
}
