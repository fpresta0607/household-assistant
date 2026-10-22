// Draft a reply: hands a text its owner got to the owner's own assistant, which drafts the
// reply as a message card in their thread for the owner to send from Messages. It is what a
// Message automation in Shortcuts runs for the people its owner picks (ReplyAutomationPage),
// and what Siri runs as "Draft a reply with Corey". It sends nothing to anyone else.
//
// One Steward AI: on Franco's iPhone it goes to Corey, on Gia's to Denise, since each phone
// has only its own assistant. Runs in the app's process without opening it, through the same
// connection the screens use.

import AppIntents

struct DraftReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft a reply"
    static let description = IntentDescription("Sends a text you got to your assistant, who drafts a reply for you to send yourself.")
    static let openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String?

    @Parameter(title: "From")
    var sender: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Draft a reply to \(\.$text) from \(\.$sender)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let text else {
            throw $text.needsValueError(IntentDialog(stringLiteral: "What did the text say?"))
        }
        guard let received = ReceivedText(words: text, sender: sender) else {
            return .result(dialog: IntentDialog(stringLiteral: "That text has no words for \(model.assistantName) to answer."))
        }
        do {
            guard try await model.draftReply(to: received) else {
                return .result(dialog: IntentDialog(stringLiteral: "\(model.assistantName) did not get the text. Try again."))
            }
            return .result(dialog: IntentDialog(stringLiteral: "\(model.assistantName) is drafting your reply."))
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: "I could not reach \(model.assistantName). \(ErrorText.describe(error))"))
        }
    }
}
