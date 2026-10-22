// What a mention is, by the household's decision 1006757: an @ and a participant's display
// name, as the room lists them, inside the words the phone signs. The gateways decide it
// with mentions.js, and this decides it the same way, so a bubble draws as a mention
// exactly the names a gateway woke someone for. Case does not matter, the name must end
// where the mention does, so "@Gia" mentions Gia and "@Giant" does not, and an @ inside a
// word, as in an email address, is no mention.
//
// An assistant's Telegram bot counts as its name, as it does on the gateways: a bot's
// username is letters, digits and underscores ending in "bot", so "@Denise_the_woman_bot"
// mentions Denise, and a bubble draws it as "@Denise", the mention this phone's @ writes.
// Each assistant learned to write the other's bot in the household's Telegram group, and on
// 19 October Corey wrote it in the app's family room. The gateways now write "@Denise" there
// themselves; this draws the messages from before, and any that still say it, the same way.
//
// A bubble draws each one: who it names and where, lit when it names this phone's own
// person or assistant. VoiceOver says it as "mentions Corey". An assistant's Markdown
// carries each as a link to whom it names, so a tap can open their page.

import Foundation

extension Mention {
    /// One mention in a message's words.
    struct Span: Equatable {
        let participant: RoomParticipant
        /// Where "@Name", or the name's Telegram bot, is written, the @ included.
        let range: Range<String.Index>
        /// Whether it names this phone's own person or its own assistant.
        let isMine: Bool
        /// What a bubble draws for it: the mention as written, or "@" and the name for the
        /// name's Telegram bot.
        let shown: String
    }

    /// The scheme of the links an assistant's Markdown carries its mentions in. It is no
    /// place outside the room, so nothing but the room opens one.
    private static let linkScheme = "steward-mention"

    /// Whether `text` mentions someone called `name`.
    static func isMentioned(_ name: String, in text: String) -> Bool {
        !ranges(of: name, in: text).isEmpty
    }

    /// Every mention in `text` of someone in the room, in the order they are written. Of
    /// two names that start at the same @, "@Gia Marie" and "@Gia", the longer is meant.
    static func spans(in text: String, participants: [RoomParticipant], me: RoomSelf?) -> [Span] {
        let found = participants.flatMap { participant in
            ranges(of: participant.name, in: text).map { written in
                Span(
                    participant: participant,
                    range: written.range,
                    isMine: participant.id == me?.person || participant.id == me?.assistant,
                    shown: written.isBot ? "@" + participant.name : String(text[written.range])
                )
            }
        }
        let ordered = found.sorted { first, second in
            if first.range.lowerBound != second.range.lowerBound {
                return first.range.lowerBound < second.range.lowerBound
            }
            return first.range.upperBound > second.range.upperBound
        }
        var kept: [Span] = []
        for span in ordered where kept.last.map({ span.range.lowerBound >= $0.range.upperBound }) ?? true {
            kept.append(span)
        }
        return kept
    }

    /// `text` as VoiceOver says it, each mention as "mentions" and the name.
    static func spoken(_ text: String, spans: [Span]) -> String {
        replacing(spans, in: text) { span in
            "mentions " + span.participant.name
        }
    }

    /// An assistant's Markdown with each mention made a link to whom it names, its words
    /// kept as written and any Markdown in them escaped.
    static func linked(_ markdown: String, spans: [Span]) -> String {
        replacing(spans, in: markdown) { span in
            "[" + escaped(span.shown) + "](" + url(for: span.participant).absoluteString + ")"
        }
    }

    /// The link a mention of `participant` carries, `steward-mention:corey`.
    static func url(for participant: RoomParticipant) -> URL {
        var parts = URLComponents()
        parts.scheme = linkScheme
        parts.path = participant.id
        // With no host, any path makes a URL: the components percent-encode what they must.
        return parts.url!
    }

    /// Who a mention's link names, or nil for any other link.
    static func participantId(in url: URL) -> String? {
        guard url.scheme?.lowercased() == linkScheme, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path else {
            return nil
        }
        return path.isEmpty ? nil : path
    }

    /// Where `text` mentions `name`, each range from the @ to the end of the name, or of the
    /// name's Telegram bot, and whether it is the bot.
    private static func ranges(of name: String, in text: String) -> [(range: Range<String.Index>, isBot: Bool)] {
        guard !name.isEmpty else {
            return []
        }
        var found: [(range: Range<String.Index>, isBot: Bool)] = []
        var next = text.startIndex
        while let at = text[next...].firstIndex(of: "@") {
            next = text.index(after: at)
            if at > text.startIndex, isWordCharacter(text[text.index(before: at)]) {
                continue
            }
            guard let named = text.range(of: name, options: [.anchored, .caseInsensitive], range: next..<text.endIndex) else {
                continue
            }
            let bot = botEnd(in: text, after: named.upperBound)
            let end = bot ?? named.upperBound
            if end < text.endIndex, isWordCharacter(text[end]) {
                continue
            }
            found.append((at..<end, bot != nil))
            next = end
        }
        return found
    }

    /// Where the rest of a Telegram bot's username after a name ends, as "_the_woman_bot"
    /// after "@Denise": letters, digits and underscores that end in "bot". Nil when there is
    /// no such rest.
    private static func botEnd(in text: String, after start: String.Index) -> String.Index? {
        let rest = text[start...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return rest.lowercased().hasSuffix("bot") ? rest.endIndex : nil
    }

    /// A letter or a digit in any script, which neither a mention may follow nor a name be
    /// followed by.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// `text` with each span put back as `replacement` makes it.
    private static func replacing(_ spans: [Span], in text: String, with replacement: (Span) -> String) -> String {
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += text[cursor..<span.range.lowerBound] + replacement(span)
            cursor = span.range.upperBound
        }
        return result + text[cursor...]
    }

    /// Words that Markdown would otherwise read as emphasis, code or a link of their own.
    private static func escaped(_ words: String) -> String {
        var escaped = ""
        for character in words {
            if "\\`*_[]<>".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
