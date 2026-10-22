// A replied-to message as its words read, for the composer's reply strip and the quote
// over a reply: an assistant's cards as the lines they show, and Markdown drawn rather
// than spelled out, so a preview never shows asterisks or a card's JSON.

import SwiftUI

enum ReplyPreview {
    static func text(of message: String, isAssistant: Bool) -> AttributedString {
        let words = isAssistant ? MessagePlainText.text(of: message, calendar: .current) : message
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: words, options: options)) ?? AttributedString(words)
    }
}
