// The one intent: ask the assistant a question, get the reply as text.
//
// Runs in the app's process without opening it, through the same connection
// the screens use. The assistant's name in Siri's prompt is the one the
// gateway reported; nothing here knows who the assistant is.

import AppIntents

struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask your assistant"
    static let description = IntentDescription("Asks your household assistant a question and returns the reply.")
    static let openAppWhenRun = false

    @Parameter(title: "Question")
    var question: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        guard let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $question.needsValueError(IntentDialog(stringLiteral: "What should I ask \(model.assistantName)?"))
        }
        do {
            let reply = try await model.ask(question)
            return .result(value: reply, dialog: IntentDialog(stringLiteral: Self.plainText(reply)))
        } catch let ranBadly as GatewayErrorShape where ranBadly.code == RoomModel.sendFailureCode {
            // The assistant was reached and refused the message; say why, rather
            // than apologising for a connection that worked.
            return .result(value: "", dialog: IntentDialog(stringLiteral: ranBadly.message))
        } catch {
            let apology = "I could not reach \(model.assistantName). \(ErrorText.describe(error))"
            return .result(value: "", dialog: IntentDialog(stringLiteral: apology))
        }
    }

    /// Markdown markers are for eyes; spoken by Siri, they are noise.
    private static func plainText(_ markdown: String) -> String {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return markdown
        }
        return String(attributed.characters)
    }
}
