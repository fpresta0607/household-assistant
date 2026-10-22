// Makes the intents available to Siri with no setup: "Ask Steward AI" and "Draft a reply
// with Steward AI", and through the app's alternative names in project.yml, "Ask Corey" and
// "Draft a reply with Denise". Draft a reply is also the action a Message automation runs in
// Shortcuts (ReplyAutomationPage).

import AppIntents

struct StewardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAssistantIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask your assistant",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: DraftReplyIntent(),
            phrases: [
                "Draft a reply with \(.applicationName)",
            ],
            shortTitle: "Draft a reply",
            systemImageName: "text.bubble"
        )
    }
}
