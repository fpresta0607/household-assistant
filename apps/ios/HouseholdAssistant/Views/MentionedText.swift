// A person's words with each @mention drawn as one (Model/Mention+Matching.swift): the name
// in semibold, gold for an assistant and royal for a person, with no background box.
// On the person's own royal bubble
// a person's name is white and an assistant's a brighter gold, so both read on it. An
// assistant's mention is a link, which the room opens as that assistant's page.

import SwiftUI

struct MentionedText: View {
    let text: String
    let spans: [Mention.Span]
    /// Drawn on the person's own royal bubble rather than a light one.
    let isOnOwnBubble: Bool

    var body: some View {
        // SwiftUI draws a link in the tint, and the only links here are assistants' names.
        Text(attributed)
            .tint(assistantColor)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for span in spans {
            result += AttributedString(String(text[cursor..<span.range.lowerBound]))
            result += mention(span)
            cursor = span.range.upperBound
        }
        return result + AttributedString(String(text[cursor...]))
    }

    private func mention(_ span: Mention.Span) -> AttributedString {
        var mention = AttributedString(span.shown)
        mention.font = Font.body.weight(.semibold)
        if span.participant.kind == .assistant {
            mention.foregroundColor = assistantColor
            mention.link = Mention.url(for: span.participant)
        } else {
            mention.foregroundColor = isOnOwnBubble ? Palette.userBubbleText : Palette.highlight
        }
        return mention
    }

    private var assistantColor: Color {
        isOnOwnBubble ? Palette.ownMention : Palette.goldText
    }

}
