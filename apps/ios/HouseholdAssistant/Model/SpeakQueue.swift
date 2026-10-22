// Talk's voice as a queue with no I/O: each sentence of the reply is asked of the gateway
// as speech, and the sentences play in the order they were said, never the order their
// audio arrived. Only the one playing and the one after it are asked for, so the next is
// ready by the time the current one ends and nothing is spoken that the person may cut
// short first. Inputs in, effects out; TalkVoice performs them.
//
// Every sentence has a number of its own that is never used again, so audio asked for
// before a stop can never be taken for a sentence after it.

import Foundation

struct SpeakQueue: Equatable, Sendable {
    enum Effect: Equatable, Sendable {
        /// Ask the gateway to speak this sentence.
        case fetch(id: Int, text: String)
        /// Play this sentence's audio now.
        case play(id: Int)
    }

    private struct Sentence: Equatable, Sendable {
        let id: Int
        let text: String
    }

    /// How many sentences after the one playing are asked for ahead of their turn.
    static let ahead = 1

    /// The sentence playing, if any.
    private(set) var playing: Int?
    /// The sentences not yet said to their end, in order: the one playing or next to play first.
    private var waiting: [Sentence] = []
    private var asked: Set<Int> = []
    private var arrivedAudio: Set<Int> = []
    private var nextId = 0

    var isEmpty: Bool {
        waiting.isEmpty
    }

    mutating func add(_ sentences: [String]) -> [Effect] {
        for text in sentences {
            waiting.append(Sentence(id: nextId, text: text))
            nextId += 1
        }
        return advance()
    }

    /// The audio for sentence `id` is on the phone.
    mutating func arrived(_ id: Int) -> [Effect] {
        guard waiting.contains(where: { $0.id == id }) else {
            return []
        }
        arrivedAudio.insert(id)
        return advance()
    }

    /// Sentence `id` was played to its end.
    mutating func finished(_ id: Int) -> [Effect] {
        guard playing == id else {
            return []
        }
        playing = nil
        waiting.removeFirst()
        asked.remove(id)
        arrivedAudio.remove(id)
        return advance()
    }

    /// Cut short, or the talk ended: everything waiting is forgotten.
    mutating func stop() {
        playing = nil
        waiting = []
        asked = []
        arrivedAudio = []
    }

    /// Whether a failure to speak is the gateway's ceiling for the day, which it refuses
    /// with `LIMIT`, rather than anything else going wrong.
    static func isUsedUp(_ error: Error) -> Bool {
        (error as? GatewayErrorShape)?.code == "LIMIT"
    }

    /// Plays the next sentence the moment its audio is in, then asks for whatever is
    /// now within reach.
    private mutating func advance() -> [Effect] {
        var effects: [Effect] = []
        if playing == nil, let next = waiting.first, arrivedAudio.contains(next.id) {
            playing = next.id
            effects.append(.play(id: next.id))
        }
        for sentence in waiting.prefix(1 + Self.ahead) where !asked.contains(sentence.id) {
            asked.insert(sentence.id)
            effects.append(.fetch(id: sentence.id, text: sentence.text))
        }
        return effects
    }
}
