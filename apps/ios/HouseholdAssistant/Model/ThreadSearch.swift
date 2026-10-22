// Finding words anywhere in one conversation (CFO notes section 5): in what was written, a
// card's lines included, what a voice note said, the names of files, and the words of a
// call. Each message that holds them is one match, newest first, with about a line of it
// around what was found, which the results list shows and the thread jumps to. It is pure,
// so the search runs off the main thread over a copy of the thread's messages.
//
// Case and accents do not matter, and neither do the marks Markdown writes words with, so
// "monday soccer" finds "**Monday** soccer".

import Foundation

enum ThreadSearch {
    /// What a match was found in, which its result is marked with.
    enum Source: Equatable, Sendable {
        case words, voiceNote, photo, video, file, call
    }

    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, messages, voice, files, photos, calls

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .messages: return "Messages"
            case .voice: return "Voice"
            case .files: return "Files"
            case .photos: return "Photos"
            case .calls: return "Calls"
            }
        }

        func includes(_ source: Source) -> Bool {
            switch self {
            case .all: return true
            case .messages: return source == .words
            case .voice: return source == .voiceNote
            case .files: return source == .file
            case .photos: return source == .photo || source == .video
            case .calls: return source == .call
            }
        }
    }

    struct Match: Equatable, Identifiable, Sendable {
        let messageId: String
        var rev: Int? = nil
        let author: String
        let sentAt: Date
        let source: Source
        /// About a line of what matched, with what was found in it.
        let snippet: String
        /// Where in `snippet` what was found is.
        let found: Range<String.Index>

        var id: String {
            messageId
        }
    }

    /// The most matches a search gives.
    static let mostMatches = 500
    /// How many characters of what comes before and after what was found a snippet keeps.
    static let snippetBefore = 30
    static let snippetAfter = 70

    /// Every message in `messages`, which are oldest first, that holds `query`, newest first.
    /// `heard` is what this phone heard in voice notes, by media id.
    static func matches(
        of query: String,
        in messages: [RoomMessage],
        heard: [String: String] = [:],
        calendar: Calendar = .current,
        filter: Filter = .all
    ) -> [Match] {
        let wanted = bare(query)
        guard !wanted.isEmpty else {
            return []
        }
        var found: [Match] = []
        for message in messages.reversed() {
            guard let match = match(of: wanted, in: message, heard: heard, calendar: calendar, filter: filter) else {
                continue
            }
            found.append(match)
            if found.count == mostMatches {
                break
            }
        }
        return found
    }

    /// The match after `current` in `matches`, toward older ones or newer ones. From no match,
    /// older starts at the newest.
    static func step(from current: Int?, isOlder: Bool, in matches: [Match]) -> Int? {
        guard !matches.isEmpty else {
            return nil
        }
        guard let current else {
            return isOlder ? 0 : nil
        }
        let next = current + (isOlder ? 1 : -1)
        return matches.indices.contains(next) ? next : current
    }

    private static func match(of wanted: String, in message: RoomMessage, heard: [String: String], calendar: Calendar, filter: Filter) -> Match? {
        for (source, text) in searched(message, heard: heard, calendar: calendar) where filter.includes(source) {
            if let (snippet, found) = snippet(of: wanted, in: text) {
                return Match(messageId: message.id, rev: message.rev, author: message.author, sentAt: message.sentAt, source: source, snippet: snippet, found: found)
            }
        }
        return nil
    }

    /// What of `message` is searched, in turn.
    private static func searched(_ message: RoomMessage, heard: [String: String], calendar: Calendar) -> [(Source, String)] {
        let voiceNotes = message.media.filter { $0.kind == .voice }
        // Only a message with a card is read as one: reading every message of a long thread
        // would push the thread's own readings out of the parser's cache.
        let words = message.text.contains(StewardCardParser.fence) ? MessagePlainText.text(of: message.text, calendar: calendar) : message.text
        // A voice reply's words are what it says aloud.
        var texts: [(Source, String)] = [(voiceNotes.isEmpty ? .words : .voiceNote, words)]
        // A file or picture is also found by its caption in that filter. Filter before
        // taking one match per message, so a matching caption cannot hide its attachment.
        for media in message.media where media.kind != .voice {
            texts.append((source(of: media), words))
        }
        if let said = message.heard {
            texts.append((.voiceNote, said))
        }
        texts += voiceNotes.compactMap { note in heard[note.id].map { (.voiceNote, $0) } }
        texts += message.media.compactMap { media in
            media.name.map { (source(of: media), $0) }
        }
        if let call = message.call {
            texts.append((.call, call.transcript.map(\.text).joined(separator: " ")))
        }
        return texts
    }

    private static func source(of media: RoomMedia) -> Source {
        switch media.kind {
        case .voice:
            return .voiceNote
        case .photo:
            return .photo
        case .video:
            return .video
        case .file:
            return .file
        }
    }

    /// `text` as it reads, around the first place it holds `wanted`, and where in that. What
    /// matched only in a link's address shows with the address.
    private static func snippet(of wanted: String, in text: String) -> (String, Range<String.Index>)? {
        let flat = bare(text)
        guard let flatRange = flat.range(of: wanted, options: insensitive) else {
            return nil
        }
        let reads = readable(text)
        let readsRange = reads.range(of: wanted, options: insensitive)
        let plain = readsRange == nil ? flat : reads
        let range = readsRange ?? flatRange
        var start = plain.index(range.lowerBound, offsetBy: -snippetBefore, limitedBy: plain.startIndex) ?? plain.startIndex
        // From the start of a word, not halfway into one.
        if start > plain.startIndex, let space = plain[start..<range.lowerBound].firstIndex(of: " ") {
            start = plain.index(after: space)
        }
        let end = plain.index(range.upperBound, offsetBy: snippetAfter, limitedBy: plain.endIndex) ?? plain.endIndex
        let lead = start > plain.startIndex ? "…" : ""
        let tail = end < plain.endIndex ? "…" : ""
        let snippet = lead + String(plain[start..<end]) + tail
        let foundStart = snippet.index(snippet.startIndex, offsetBy: lead.count + plain.distance(from: start, to: range.lowerBound))
        let foundEnd = snippet.index(foundStart, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
        return (snippet, foundStart..<foundEnd)
    }

    /// `text` as one line of words: Markdown's marks and a link's address left out, and every
    /// run of spaces and new lines one space.
    static func readable(_ text: String) -> String {
        var words = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        words = words.replacingOccurrences(of: #"(?m)^\s{0,3}(?:#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
        words = words.replacingOccurrences(of: #"\*\*|__|`|~~|(?<![\w*])\*(?!\s)|(?<!\s)\*(?![\w*])"#, with: "", options: .regularExpression)
        return words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `text` without the marks Markdown puts round words, as one line: what every message is
    /// first looked through, as a search can look through thousands.
    static func bare(_ text: String) -> String {
        text.filter { !emphasis.contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let emphasis: Set<Character> = ["*", "_", "`", "~"]
    private static let insensitive: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
}

