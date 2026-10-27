// A person's words with each @mention drawn as one (Model/Mention+Matching.swift): the name
// in semibold, gold for an assistant and royal for a person, with no background box.
// On the person's own royal bubble
// a person's name is white and an assistant's a brighter gold, so both read on it. An
// assistant's mention is a link, which the room opens as that assistant's page.

import SwiftUI
import UIKit

struct MentionedText: View {
    let text: String
    let spans: [Mention.Span]
    /// Drawn on the person's own royal bubble rather than a light one.
    let isOnOwnBubble: Bool
    @Environment(\.readingStyle) private var style

    var body: some View {
        InlineMessageText(text: attributed, tint: assistantColor)
            // UIViewRepresentable text does not automatically contribute its value
            // to the bubble's combined VoiceOver label as SwiftUI Text did.
            .accessibilityLabel(text)
    }

    private var attributed: NSAttributedString {
        let font = style.selectionFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(isOnOwnBubble ? Palette.userBubbleText : Palette.otherBubbleText)
        ]
        let result = NSMutableAttributedString(string: "")
        var cursor = text.startIndex
        for span in spans {
            result.append(NSAttributedString(string: String(text[cursor..<span.range.lowerBound]), attributes: attributes))
            var mention = attributes
            mention[.font] = style.config.paragraphStyle.textFonts.bold ?? font
            mention[.foregroundColor] = UIColor(span.participant.kind == .assistant
                ? assistantColor : (isOnOwnBubble ? Palette.userBubbleText : Palette.highlight))
            if span.participant.kind == .assistant { mention[.link] = Mention.url(for: span.participant) }
            result.append(NSAttributedString(string: span.shown, attributes: mention))
            cursor = span.range.upperBound
        }
        result.append(NSAttributedString(string: String(text[cursor...]), attributes: attributes))
        return result
    }

    private var assistantColor: Color {
        isOnOwnBubble ? Palette.ownMention : Palette.goldText
    }

}
