// When the person has finished their turn in a call: a natural pause after the last change
// in what was heard, as a person on the phone would take it.
//
// The recognizer keeps revising its words while it listens, so the clock runs from the
// last time the words changed, not from the last sound. A change of punctuation or
// capitals alone is the recognizer tidying up once the person has stopped, so it does
// not restart the clock, or every turn would wait longer than it needs to. Nothing ends
// before something has been said.
//
// Seven tenths of a second after real words ends the turn. Complete short replies such
// as "yes" have a shorter pause. A very short fragment ("Hey Corey", "So") or words that stop
// where a sentence cannot ("and", "the", "um") are someone still finding what to say, so
// they get a little longer.

import Foundation

struct UtteranceEnd: Equatable, Sendable {
    /// How long a pause ends a turn after real words.
    static let pause: TimeInterval = 0.7
    /// A complete short answer need not wait as though it were an unfinished fragment.
    static let answerPause: TimeInterval = 0.55
    private static let shortAnswers: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "okay", "ok", "sure", "done",
        "thanks", "thank you", "bye", "goodbye", "stop", "cancel",
        "go ahead", "do it", "sounds good", "that's right",
    ]
    /// How long a pause ends a turn after a very short fragment, or after words that stop
    /// mid-phrase.
    static let longerPause: TimeInterval = 1.6
    /// A fragment of at most this many words waits the longer pause.
    static let shortFragmentWords = 2
    /// Words a sentence goes on after: joining words, articles, a few prepositions and the
    /// sounds of someone thinking.
    static let unfinishedEndings: Set<String> = [
        "and", "but", "or", "so", "because", "if", "then", "that",
        "the", "a", "an", "my", "your",
        "to", "of", "for", "with", "at", "in", "on", "about",
        "um", "uh", "erm", "hmm",
    ]

    /// What was heard, as the recognizer last wrote it.
    private(set) var heard = ""
    private var words: [String] = []
    private var changedAt: Date?

    mutating func hear(_ text: String, at moment: Date) {
        heard = text
        let said = Self.words(in: text)
        if said != words {
            words = said
            changedAt = moment
        }
    }

    /// How long a pause ends this turn, from what has been said so far.
    var pauseNeeded: TimeInterval {
        guard let last = words.last else {
            return Self.pause
        }
        if Self.shortAnswers.contains(words.joined(separator: " ")) {
            return Self.answerPause
        }
        return words.count <= Self.shortFragmentWords || Self.unfinishedEndings.contains(last) ? Self.longerPause : Self.pause
    }

    func isOver(at moment: Date) -> Bool {
        guard !words.isEmpty, let changedAt else {
            return false
        }
        return moment.timeIntervalSince(changedAt) >= pauseNeeded
    }

    /// What a piece of speech says rather than how it is written: its words, lowercased,
    /// without punctuation. An apostrophe inside a word stays part of it.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !isWordCharacter($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// `text` as written after its first `count` words, `words(in:)`'s words, without the
    /// spaces and punctuation before the next one.
    static func dropping(_ count: Int, wordsFrom text: String) -> String {
        var rest = Substring(text)
        for _ in 0..<count {
            guard let start = rest.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
                return ""
            }
            rest = rest[start...].drop(while: isWordCharacter)
        }
        return String(rest.drop { !$0.isLetter && !$0.isNumber })
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }
}
