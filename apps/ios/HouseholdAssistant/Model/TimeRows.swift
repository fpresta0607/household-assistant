// A list in an assistant's reply whose every item starts with a time, "- 4:10 PM Gia lands",
// drawn as tidy rows with the time in a chip rather than as bullets. A list with any item
// that does not start with a time stays the Markdown it is, and so does everything around
// a list of times, exactly as written, so a reply still arriving hands its renderer the
// same words it would have had.
//
// While a reply arrives its rows come line by line: an unfinished last item that may yet
// turn out to start with a time waits for its line to end, rather than showing as a
// bullet and then jumping into a row.

import Foundation

enum TimeRows {
    struct Row: Equatable {
        /// "4:10 PM" or "17:45": the time as written, its AM or PM in capitals.
        let time: String
        /// The rest of the item, as Markdown.
        let words: String
    }

    enum Block: Equatable {
        case markdown(String)
        case rows([Row])
    }

    /// Characters that may stand between the time and the words: "8:00 PM - Movie night".
    private static let separators: Set<Character> = ["-", "\u{2013}", "\u{2014}", "\u{00B7}"]

    static func blocks(in markdown: String, isStreaming: Bool) -> [Block] {
        var lines = lineRanges(of: markdown)
        // An unfinished last line that may yet start with a time waits for the rest of it.
        var shownEnd = markdown.endIndex
        if isStreaming, let last = lines.last, last.end == markdown.endIndex, mayBecomeTime(markdown[last.start..<last.end]) {
            lines.removeLast()
            shownEnd = last.start
        }

        var blocks: [Block] = []
        var markdownStart = markdown.startIndex
        var index = 0
        while index < lines.count {
            var runEnd = index
            var rows: [Row] = []
            var isEveryItemATime = true
            while runEnd < lines.count, let item = listItem(in: markdown[lines[runEnd].start..<lines[runEnd].end]) {
                if let row = timeRow(item) {
                    rows.append(row)
                } else {
                    isEveryItemATime = false
                }
                runEnd += 1
            }
            if runEnd > index, isEveryItemATime {
                appendMarkdown(markdown[markdownStart..<lines[index].start], to: &blocks)
                blocks.append(.rows(rows))
                markdownStart = lines[runEnd - 1].next
            }
            index = max(runEnd, index + 1)
        }
        appendMarkdown(markdown[markdownStart..<shownEnd], to: &blocks)
        return blocks
    }

    /// Each line: where it starts, where its words end, and where the next line starts.
    private static func lineRanges(of text: String) -> [(start: String.Index, end: String.Index, next: String.Index)] {
        var lines: [(start: String.Index, end: String.Index, next: String.Index)] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let next = end < text.endIndex ? text.index(after: end) : end
            lines.append((start, end, next))
            start = next
        }
        return lines
    }

    /// Markdown worth showing: anything but blank lines.
    private static func appendMarkdown(_ text: Substring, to blocks: inout [Block]) {
        if !text.allSatisfy(\.isWhitespace) {
            blocks.append(.markdown(String(text)))
        }
    }

    /// What follows a list item's marker, for an item at the start of its line.
    private static func listItem(in line: Substring) -> Substring? {
        guard let marker = line.first, "-*+".contains(marker) else {
            return nil
        }
        let rest = line.dropFirst()
        guard rest.first?.isWhitespace == true else {
            return nil
        }
        return rest.drop(while: \.isWhitespace)
    }

    /// An item begun but not finished that could still start with a time: a marker alone,
    /// or one followed by a digit, bold or not.
    private static func mayBecomeTime(_ line: Substring) -> Bool {
        if line.count == 1, let marker = line.first, "-*+".contains(marker) {
            return true
        }
        guard let item = listItem(in: line) else {
            return false
        }
        return item.drop { $0 == "*" }.first.map(\.isNumber) ?? true
    }

    /// The item as a row, when it starts with a time and has words after it.
    private static func timeRow(_ item: Substring) -> Row? {
        let isBold = item.hasPrefix("**")
        guard case let (shown, afterTime)? = time(at: isBold ? item.dropFirst(2) : item) else {
            return nil
        }
        var rest = afterTime
        if isBold {
            guard rest.hasPrefix("**") else {
                return nil
            }
            rest = rest.dropFirst(2)
        }
        if rest.first == ":" {
            rest = rest.dropFirst()
        } else if rest.first?.isWhitespace != true {
            return nil
        }
        rest = rest.drop(while: \.isWhitespace)
        if let first = rest.first, separators.contains(first), rest.dropFirst().first?.isWhitespace == true {
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        }
        let words = rest.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : Row(time: shown, words: words)
    }

    /// The time at the start of `text`, "4:10", "17:45", "4:10pm" or "7:05 a.m.", as it is
    /// shown, and what follows it. Nil when it is not a time of day.
    private static func time(at text: Substring) -> (String, Substring)? {
        let hours = text.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(hours.count), let hour = Int(hours) else {
            return nil
        }
        var rest = text.dropFirst(hours.count)
        guard rest.first == ":" else {
            return nil
        }
        rest = rest.dropFirst()
        let minutes = rest.prefix(2)
        guard minutes.count == 2, minutes.allSatisfy({ $0.isASCII && $0.isNumber }), let minute = Int(minutes), minute < 60 else {
            return nil
        }
        rest = rest.dropFirst(2)
        let clock = "\(hours):\(minutes)"
        guard case let (half, afterHalf)? = meridiem(at: rest) else {
            return hour < 24 ? (clock, rest) : nil
        }
        return (1...12).contains(hour) ? (clock + " " + half, afterHalf) : nil
    }

    /// "AM" or "PM" at the start of `text`, written "pm", " PM" or " p.m.", and what follows.
    private static func meridiem(at text: Substring) -> (String, Substring)? {
        var rest = text.first == " " ? text.dropFirst() : text
        guard let half = rest.first?.uppercased(), half == "A" || half == "P" else {
            return nil
        }
        rest = rest.dropFirst()
        if rest.first == "." {
            rest = rest.dropFirst()
        }
        guard rest.first?.uppercased() == "M" else {
            return nil
        }
        rest = rest.dropFirst()
        if rest.first == "." {
            rest = rest.dropFirst()
        }
        return (half + "M", rest)
    }
}
