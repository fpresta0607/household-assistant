// The Contacts connector's switch, in Connectors and on its page. Turning it on asks iOS the
// one time it never has, where its person shares everyone or only the people they pick, and
// it stays on only once iOS says yes. While iOS says no it shows off and holds still, and
// the page offers the iPhone's Settings instead. Off needs nothing.
//
// The system's own green, as every connector's switch: royal is never a fill.

import SwiftUI

struct ContactsSwitch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    /// While iOS's question is on screen, the switch shows on.
    @State private var isAsking = false

    var body: some View {
        let connector = model.contactsConnector
        HStack(spacing: 8) {
            if isAsking {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle("Contacts", isOn: Binding { connector.isSwitchedOn || isAsking } set: { isOn in turn(isOn) })
                .labelsHidden()
                .disabled(isAsking || connector.access.isUpToIOS)
                .accessibilityIdentifier("connector.contacts.switch")
        }
    }

    private func turn(_ isOn: Bool) {
        guard isOn else {
            withAnimation(Motion.flip(reduced: reduceMotion)) {
                model.settings.shouldLookInContacts = false
            }
            return
        }
        isAsking = true
        Task {
            await model.permissions.requestContacts()
            let access = model.permissions.state(of: .contacts)
            withAnimation(Motion.flip(reduced: reduceMotion)) {
                isAsking = false
                model.settings.shouldLookInContacts = access == .allowed || access == .limited
            }
        }
    }
}
