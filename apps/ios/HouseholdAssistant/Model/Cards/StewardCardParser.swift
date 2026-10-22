// Splits an assistant's message into Markdown and cards.
//
// A card is a fenced block whose opening line is exactly ```steward-card and whose body
// is one JSON object. An ordinary Markdown table becomes a table card too, so it is drawn
// natively. Anything inside another fenced code block stays as written.
//
// While a reply streams, nothing half-arrived may show as raw text: a card whose block
// has not closed is a placeholder, a line that may yet become a card's opening fence or
// a table's header is held back, and a table shows only its whole rows. Once the reply is
// over, whatever was never closed is read as well as it can be, and what is not a card
// shows as the text it is.
//
// Follow-ups are not drawn in the bubble but as chips under it, so they are never a
// segment, not even a placeholder while their block arrives. `followups(in:)` finds them.
//
// A message is read once for each text it has. Its bubble, its skill's badge, its
// follow-ups, what VoiceOver says of it and the cart check all ask for the same reading,
// and the thread asks again whenever anything in it changes, so the reading is kept.

import Foundation

enum StewardCardParser {
    static let fence = "```steward-card"

    /// What a message reads as: its pieces in order, and the follow-ups it offers.
    struct Reading: Sendable {
        let segments: [MessageSegment]
        let followups: FollowupsCard?
    }

    /// Finished messages' readings, by their text.
    static let finished = BoundedCache<String, Reading>(capacity: 512)
    /// A reply still streaming has a new text with each piece that arrives, so its readings
    /// are kept apart, a few at a time, where they never push a finished message out.
    static let streaming = BoundedCache<String, Reading>(capacity: 8)

    static func segments(in text: String, isStreaming: Bool) -> [MessageSegment] {
        read(text, isStreaming: isStreaming).segments
    }

    /// What a finished message says in its own words: its Markdown, code blocks and tables'
    /// header and cells, with every other card left out. A link a card carries is the card's
    /// to show, such as a scripture card's Open in Bible, so the bubble previews only links
    /// from these.
    static func prose(in text: String) -> String {
        segments(in: text, isStreaming: false)
            .compactMap { segment -> String? in
                switch segment {
                case .markdown(let words), .code(let words):
                    return words
                case .card(let card):
                    guard case .table(let table) = card.content else {
                        return nil
                    }
                    return ([table.columns] + table.rows).map { $0.joined(separator: " ") }.joined(separator: "\n")
                case .pendingCard:
                    return nil
                }
            }
            .joined(separator: "\n")
    }

    /// The follow-ups a finished answer offers: the first block of them. Nil for none.
    static func followups(in text: String) -> FollowupsCard? {
        read(text, isStreaming: false).followups
    }

    private static func read(_ text: String, isStreaming: Bool) -> Reading {
        (isStreaming ? streaming : finished).value(for: text) {
            parse(text, isStreaming: isStreaming)
        }
    }

    private static func parse(_ text: String, isStreaming: Bool) -> Reading {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        let isLastLineWhole = normalized.hasSuffix("\n")
        if isLastLineWhole {
            lines.removeLast()
        }
        // The line still arriving, which may yet be the start of something else.
        let openLine = isStreaming && !isLastLineWhole ? lines.count - 1 : nil

        var segments: [MessageSegment] = []
        var followups: FollowupsCard?
        var prose: [String] = []
        var codeFence: Substring?
        var index = 0

        func keepProse() {
            let markdown = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            prose = []
            if !markdown.trimmingCharacters(in: .whitespaces).isEmpty {
                segments.append(.markdown(markdown))
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let opened = codeFence {
                prose.append(line)
                if closes(opened, trimmed) {
                    codeFence = nil
                }
                index += 1
                continue
            }
            if trimmed == fence {
                keepProse()
                var body: [String] = []
                var cursor = index + 1
                while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces) != "```" {
                    body.append(lines[cursor])
                    cursor += 1
                }
                let isClosed = cursor < lines.count
                let json = body.joined(separator: "\n")
                if isClosed || !isStreaming {
                    if let offered = try? JSONDecoder().decode(FollowupsCard.self, from: Data(json.utf8)) {
                        followups = followups ?? offered
                    } else {
                        segments.append(card(from: json))
                    }
                } else if !namesFollowups(json) {
                    segments.append(.pendingCard)
                }
                index = cursor + 1
                continue
            }
            if index == openLine, !trimmed.isEmpty, fence.hasPrefix(trimmed) {
                break
            }
            if let opener = codeFenceOpener(trimmed) {
                codeFence = opener
                prose.append(line)
                index += 1
                continue
            }
            if trimmed.hasPrefix("|") {
                if case let (found, next)? = table(at: index, in: lines, openLine: openLine) {
                    keepProse()
                    segments.append(.card(StewardCard(content: .table(found), skill: nil)))
                    index = next
                    continue
                }
                if isStreaming, mayBecomeTable(at: index, in: lines, openLine: openLine) {
                    break
                }
            }
            prose.append(line)
            index += 1
        }
        keepProse()
        return Reading(segments: segments, followups: followups)
    }

    /// The skill that answered a message, whose badge sits above its bubble: the first of
    /// its cards to wear one. Nil for a plain answer.
    static func skill(in text: String, isStreaming: Bool) -> CardSkill? {
        for case .card(let card) in segments(in: text, isStreaming: isStreaming) {
            if let skill = card.skill {
                return skill
            }
        }
        return nil
    }

    private static func card(from json: String) -> MessageSegment {
        guard let card = try? JSONDecoder().decode(StewardCard.self, from: Data(json.utf8)) else {
            return .code(json.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .card(card)
    }

    /// Whether a card still arriving has already said it is follow-ups.
    private static func namesFollowups(_ json: String) -> Bool {
        json.range(of: #""type"\s*:\s*"\#(FollowupsCard.type)""#, options: .regularExpression) != nil
    }

    /// The run of backticks or tildes that opens an ordinary fenced code block.
    private static func codeFenceOpener(_ trimmed: String) -> Substring? {
        guard let mark = trimmed.first, mark == "`" || mark == "~" else {
            return nil
        }
        let run = trimmed.prefix { $0 == mark }
        return run.count >= 3 ? run : nil
    }

    /// A closing fence is the same mark, at least as long, and nothing else.
    private static func closes(_ opener: Substring, _ trimmed: String) -> Bool {
        guard let mark = opener.first else {
            return false
        }
        return trimmed.count >= opener.count && trimmed.allSatisfy { $0 == mark }
    }

    /// A table starting at `index`, and the line after it. A row still arriving is left
    /// for later, so the table grows a whole row at a time.
    private static func table(at index: Int, in lines: [String], openLine: Int?) -> (TableCard, Int)? {
        let delimiter = index + 1
        guard delimiter < lines.count, delimiter != openLine else {
            return nil
        }
        var cursor = delimiter + 1
        var rows: [String] = []
        while cursor < lines.count, cursor != openLine, lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            rows.append(lines[cursor])
            cursor += 1
        }
        guard let table = TableCard.markdown(header: lines[index], delimiter: lines[delimiter], rows: rows) else {
            return nil
        }
        return (table, cursor)
    }

    /// A header with nothing after it yet, or with the start of its delimiter row.
    private static func mayBecomeTable(at index: Int, in lines: [String], openLine: Int?) -> Bool {
        let next = index + 1
        if next == lines.count {
            return true
        }
        return next == openLine && lines[next].allSatisfy { " |:-".contains($0) }
    }
}
