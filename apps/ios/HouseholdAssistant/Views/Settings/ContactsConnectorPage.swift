// The Contacts connector's own page, opened from Connectors: its switch, who iOS lets Steward
// AI see, everyone or only the people chosen, with Settings to change them, and what the
// assistant can do with them. All of it stays on this iPhone: a drafted text finds its
// person here, and nothing from Contacts goes to the gateway. Last, how to let the assistant
// see the texts some people send (ReplyAutomationPage).
//
// Where only iOS can change it, the group says so and opens Steward AI's page in the
// iPhone's Settings; the app reads it again when it comes back to the front (Permissions).

import SwiftUI

struct ContactsConnectorPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// The people iOS lets Steward AI see while only some are shared, by name, read on the
    /// phone for this page alone.
    @State private var chosen: [String] = []

    var body: some View {
        let connector = model.contactsConnector
        let assistant = model.assistantName
        SettingsPage("Contacts") {
            SettingsGroup("On this iPhone", note: Self.note(for: connector, assistant: assistant)) {
                SettingsRow("Contacts", subtitle: connector.line, isConnected: connector.isConnected) {
                    ContactsTile(size: 48)
                } trailing: {
                    ContactsSwitch()
                }
                if connector.access.isUpToIOS {
                    OpenIPhoneSettingsRow()
                }
            }
            if connector.isConnected {
                SettingsGroup("Shared with Steward AI") {
                    if connector.access == .limited {
                        SettingsRow("Only the people you chose", subtitle: ContactsConnector.chosen(chosen)) {
                            EmptyView()
                        }
                        // The inline ContactsUI picker links symbols missing on Apple
                        // silicon Macs (ITMS-90863). System Settings edits the same
                        // limited-access list without importing that picker.
                        OpenIPhoneSettingsRow()
                            .accessibilityIdentifier("contacts.choose-people")
                    } else {
                        SettingsRow("All your contacts") {
                            EmptyView()
                        }
                        OpenIPhoneSettingsRow()
                    }
                }
            }
            SettingsGroup("What \(assistant) can do") {
                ForEach(Self.abilities, id: \.self) { ability in
                    AssistantAbility(text: ability)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            SettingsGroup {
                NavigationLink {
                    ReplyAutomationPage()
                } label: {
                    SettingsRow("Let \(assistant) see texts", subtitle: "From people you choose, with a Shortcut") {
                        RowValue()
                    }
                }
                .buttonStyle(.settingsRow)
            }
        }
        // Refresh after Settings even when access stays limited and only its people
        // change. Not in screenshot tests, which have no Contacts of their own.
        .task(id: scenePhase == .active ? connector : nil) {
            guard scenePhase == .active else {
                return
            }
            let isRead = connector.isConnected && connector.access == .limited && model.permissions.isAllowedToAskForContacts
            let names = isRead ? await MessageContacts.chosenNames() : []
            guard !Task.isCancelled else {
                return
            }
            chosen = names
        }
    }

    private static let abilities = [
        "Find who a text is for, on this iPhone",
        "Ask you which one when two match",
        "Nothing from your contacts leaves this iPhone",
    ]

    private static func note(for connector: ContactsConnector, assistant: String) -> String {
        if connector.access.isUpToIOS {
            return "Contacts are off for Steward AI in your iPhone's Settings, so \(assistant) cannot find who a text is for. Turn them on there to use this."
        }
        return "When \(assistant) drafts a text for you to send, Steward AI finds who it is for in your contacts on this iPhone. Only the person you send to is used, and nothing from your contacts is sent anywhere. Switching it off stops that at once."
    }
}
