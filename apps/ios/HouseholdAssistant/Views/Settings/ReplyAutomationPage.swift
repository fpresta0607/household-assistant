// How to let the assistant see the texts some people send: iOS lets no app read Messages, so
// its owner makes a Message automation in Apple's Shortcuts app, once, for the people they
// pick. Each new text from them then runs Steward AI's Draft a reply (DraftReplyIntent) with
// nothing to tap, and the assistant drafts the reply as a card in their thread. Steward AI
// cannot make the automation for them, and nothing is sent until they send it from Messages.

import SwiftUI
import UIKit

struct ReplyAutomationPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let assistant = model.assistantName
        SettingsPage("Texts to \(assistant)") {
            SettingsGroup(
                "In the Shortcuts app",
                note: "Each new text from them goes to \(assistant) as it arrives, and \(assistant) drafts your reply as a card here. Nothing is sent until you send it from Messages."
            ) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Palette.goldText)
                        Text(step)
                            .font(.subheadline)
                            .foregroundStyle(Palette.text)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            SettingsGroup(
                note: "Their texts go to \(assistant)'s gateway and the model that answers, as your own messages do, and never to anyone else's assistant. To stop, delete the automation in Shortcuts."
            ) {
                Button {
                    if let url = URL(string: "shortcuts://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow("Open Shortcuts") {
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(Palette.highlight)
                    }
                }
                .buttonStyle(.settingsRow)
            }
        }
    }

    private static let steps = [
        "Open Shortcuts, tap Automation, then New Automation.",
        "Choose Message, then pick the people under Sender.",
        "Choose Run Immediately, then tap Next.",
        "Add Draft a reply from Steward AI. Set Text to Shortcut Input and From to Sender.",
        "Tap Done.",
    ]
}
