// Turns an assistant's reply, as it streams in, into whole sentences to say aloud.
//
// Speech starts on the first sentence while the rest is still arriving. A long opening
// can start at a natural clause boundary, so speech synthesis does not wait for the whole
// sentence. Only that first chunk uses a clause boundary, keeping the rest fluid. A sentence
// is only handed out once it is whole: cut early, "3." could still become "3.5", and
// "Dr." is not an end at all. A new line always ends one, so a list is read item by
// item. Cards and code are drawn, never read, so only the reply's prose is spoken, and
// the Markdown in it is for eyes: a list's dash, a heading's hash, bold's stars and a
// link's address are left out, and so are emoji, which a voice reads out by name.

import Foundation

struct SpokenSentences: Equatable, Sendable {
    enum Progress: Equatable, Sendable {
        /// Still arriving: only what is certainly a whole sentence is handed out.
        case arriving
        /// Stopped for now while a tool runs, so the words so far are said rather than held.
        case paused
        /// Over: whatever is left is said.
        case finished
    }

    /// How much of the reply's prose has been handed out, in characters.
    private var handedOut = 0

    /// What ends a sentence when a space or a new line follows it.
    private static let enders: Set<Character> = [".", "!", "?", "\u{2026}"]
    /// What may close a sentence after its end: quotes, brackets and Markdown's marks.
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "*", "_", "`", "\u{00BB}"]
    /// Short forms whose full stop does not end a sentence. Joining two sentences only
    /// costs a moment, where splitting one in two puts a pause in the middle of it.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "approx", "no", "mt", "ft", "inc", "ltd", "co",
    ]

    /// The sentences of `reply` that have become whole since the last call.
    mutating func take(from reply: String, _ progress: Progress) -> [String] {
        let prose = Array(Self.prose(of: reply, isStreaming: progress != .finished))
        // A reply rewritten shorter than what was already said says nothing more of it.
        var start = min(handedOut, prose.count)
        var sentences: [String] = []
        func keep(upTo end: Int) {
            if let sentence = Self.spoken(String(prose[start..<end])) {
                sentences.append(sentence)
            }
            start = end
        }

        var index = start
        while index < prose.count {
            let character = prose[index]
            if character == "\n" {
                keep(upTo: index)
                start = index + 1
                index += 1
                continue
            }
            // Enough words to sound like a phrase, and only the first spoken chunk.
            // A following space protects commas in numbers and colons in times.
            if handedOut == 0, sentences.isEmpty, [",", ";", ":"].contains(character),
               index + 1 < prose.count, prose[index + 1].isWhitespace,
               index - start >= 60,
               prose[start..<index].split(whereSeparator: \.isWhitespace).count >= 8 {
                keep(upTo: index + 1)
                index += 1
                continue
            }
            guard Self.enders.contains(character) else {
                index += 1
                continue
            }
            var after = index + 1
            while after < prose.count, Self.enders.contains(prose[after]) || Self.closers.contains(prose[after]) {
                after += 1
            }
            let isShortForm = character == "." && Self.isShortForm(prose[start..<index])
            if after < prose.count, prose[after].isWhitespace, !isShortForm {
                keep(upTo: after)
            }
            index = after
        }
        if progress != .arriving {
            keep(upTo: prose.count)
        }
        handedOut = start
        return sentences
    }

    /// What a voice says for one sentence of Markdown, or nil when it says nothing.
    static func spoken(_ markdown: String) -> String? {
        let line = withoutLinks(withoutLineMarker(markdown.trimmingCharacters(in: .whitespaces)))
        var words = String(line.filter { !isEmoji($0) })
            .split(whereSeparator: \.isWhitespace)
            .filter { !isAddress($0) }
            .map(withoutMarks)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // A mark that stood between a word and its punctuation leaves a space behind.
        for mark in [".", ",", "!", "?", ";", ":"] {
            words = words.replacingOccurrences(of: " " + mark, with: mark)
        }
        return words.contains { $0.isLetter || $0.isNumber } ? words : nil
    }

    // MARK: - The prose

    /// The reply's Markdown, without its cards and code. Whatever is left out still
    /// ends the sentence before it, so the words before a card are said as soon as the
    /// card begins.
    private static func prose(of reply: String, isStreaming: Bool) -> String {
        StewardCardParser.segments(in: reply, isStreaming: isStreaming)
            .map { segment in
                if case .markdown(let markdown) = segment {
                    return withoutCode(markdown)
                }
                return ""
            }
            .joined(separator: "\n")
    }

    /// Markdown with each fenced code block's lines left out and its fences left blank.
    private static func withoutCode(_ markdown: String) -> String {
        var isInCode = false
        var lines: [Substring] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInCode.toggle()
                lines.append("")
            } else if !isInCode {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Whether the full stop after `sentence`, the sentence so far, belongs to its last
    /// word: an initial, a short form, a word with stops inside it such as "p.m", or a
    /// list's number at the start of a line.
    private static func isShortForm(_ sentence: ArraySlice<Character>) -> Bool {
        let text = String(sentence).trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, text.allSatisfy(\.isNumber) {
            return true
        }
        let word = (text.split(whereSeparator: \.isWhitespace).last ?? "").drop { !$0.isLetter && !$0.isNumber }
        if word.count == 1, word.first?.isLetter == true {
            return true
        }
        return word.contains(".") || abbreviations.contains(word.lowercased())
    }

    // MARK: - One sentence

    /// Drops a heading's hashes, a quote's mark, a bullet or a list's number, and a
    /// task's box from the start of a line.
    private static func withoutLineMarker(_ line: String) -> String {
        var rest = Substring(line)
        while let first = rest.first, first == "#" || first == ">" {
            rest = rest.dropFirst()
        }
        rest = rest.drop(while: \.isWhitespace)
        if let first = rest.first, "-*+\u{2022}".contains(first), rest.dropFirst().first?.isWhitespace == true {
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        } else {
            let number = rest.prefix(while: \.isNumber)
            let after = rest.dropFirst(number.count)
            if !number.isEmpty, let mark = after.first, mark == "." || mark == ")", after.dropFirst().first?.isWhitespace == true {
                rest = after.dropFirst().drop(while: \.isWhitespace)
            }
        }
        for box in ["[ ]", "[x]", "[X]"] where rest.hasPrefix(box) {
            rest = rest.dropFirst(box.count).drop(while: \.isWhitespace)
        }
        return String(rest)
    }

    /// A link or a picture becomes its words: "[slides](https://...)" is "slides".
    private static func withoutLinks(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            let afterOpen = rest.index(after: open)
            guard
                let close = rest[afterOpen...].firstIndex(of: "]"),
                rest[rest.index(after: close)...].first == "(",
                let end = rest[close...].firstIndex(of: ")")
            else {
                result += rest[..<afterOpen]
                rest = rest[afterOpen...]
                continue
            }
            var before = rest[..<open]
            if before.last == "!" {
                before = before.dropLast()
            }
            result += before
            result += rest[afterOpen..<close]
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    /// A web address, which nobody wants read to them.
    private static func isAddress(_ word: Substring) -> Bool {
        let bare = word.drop { "<([\"'".contains($0) }.lowercased()
        return bare.hasPrefix("http://") || bare.hasPrefix("https://") || bare.hasPrefix("www.")
    }

    /// Drops Markdown's emphasis and code marks. An underscore between two letters is
    /// part of a word, as in snake_case, so only one at a word's edge goes.
    private static func withoutMarks(_ word: Substring) -> String {
        let characters = Array(word.filter { !"*`~".contains($0) })
        var kept = ""
        for (index, character) in characters.enumerated() {
            if character == "_" {
                let before = index > 0 ? characters[index - 1] : nil
                let after = index + 1 < characters.count ? characters[index + 1] : nil
                guard let before, let after, before.isLetter || before.isNumber, after.isLetter || after.isNumber else {
                    continue
                }
            }
            kept.append(character)
        }
        return kept
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F || scalar.value == 0x20E3
        }
    }
}
