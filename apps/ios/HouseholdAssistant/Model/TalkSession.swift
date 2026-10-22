// A call's loop, hands-free: the microphone stays on for the whole call, the person's turn
// ends with a natural pause after what they said (UtteranceEnd), their words go to the
// thread, and the reply is said sentence by sentence as it streams in. Then the turn is
// theirs again, with nothing to press.
//
// The voice plays through the microphone's own audio engine, whose echo cancellation takes
// it out of what the microphone hears, so the person can talk over the assistant as on a
// phone call: real words heard while it speaks or thinks stop it at once and open their
// turn. Words that are all words the voice has said this turn are its echo getting past
// the cancellation, so they are not taken for the person's, and a turn they cut in with
// starts after them. A word or two that only stops someone, such as wait or no, still
// cuts in, though the voice said it too.
//
// Muted, nothing is heard, so nothing is sent and nothing cuts in, and unmuting picks up
// from there. Muting never cuts the assistant off: a reply being said is said to its end.
// Only hanging up stops it mid-sentence, and the word "stop" said on its own hangs up.
//
// On hold, for a phone call the person takes or for Siri (CallState), nothing is heard or
// said: the voice stops at once and no turn ends, while a reply still arriving is kept.
// Off hold, the sentence the hold cut off is said again from its start, then the rest,
// and a turn that was open starts afresh.
//
// No dead air: when nothing has been said a moment and a half after the person's words
// went, a short holding line ("One sec.") is said in the assistant's voice from the
// phone's own copy, one a turn, the lines taking turns so none is said twice running. The
// assistant is asked to say its own line before anything slow (CALL_TURN_INSTRUCTION in
// the household-app plugin), which usually comes first.
//
// Once the gateway says today's voice is used up, nothing more is said aloud: each reply
// shows in words as it arrives. Pure: inputs in, one effect out, and the view model
// performs the effect.

import Foundation

struct TalkSession: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// The person's turn is open.
        case listening
        /// Their words were sent, and the assistant is thinking: nothing is being said.
        case waiting
        /// Saying the reply, or a holding line. Real words heard stop it.
        case speaking
        case ended
        /// Something went wrong. A tap listens again.
        case failed(String)
    }

    enum Input: Equatable, Sendable {
        /// The call opened.
        case began
        case heard(String, at: Date)
        case tick(Date)
        /// The reply to what was sent, as far as it has come.
        case reply(String, isFinished: Bool)
        /// What the assistant's run is busy with, or nil while it thinks.
        case working(AssistantActivity?)
        /// The voice said one sentence, or the holding line, to its end.
        case saidSentence
        /// The gateway refused to speak: its ceiling for the day is reached.
        case voiceUsedUp
        /// The person muted the microphone, or unmuted it.
        case muted(Bool)
        /// The call went on hold, or came off it.
        case held(Bool)
        /// The face was tapped. Only a failure answers it, by listening again.
        case tapped
        /// End Call.
        case hungUp
        case failed(String)
    }

    enum Effect: Equatable, Sendable {
        case none
        /// Start hearing from nothing: the microphone on, and a turn with no words yet.
        case listen
        /// Send these words to the thread. The microphone stays on, and the next words
        /// heard start afresh.
        case send(String)
        /// Say these sentences after any still queued.
        case say([String])
        /// Say this holding line now, from the phone's own copy.
        case hold(String)
        /// Stop saying anything at once. The microphone stays on, and keeps what it heard.
        case interrupt
        /// Mute the microphone, or unmute it. The voice is not touched.
        case mute(Bool)
        /// Stop saying anything at once, for the call is on hold. What was cut off is said
        /// again once it comes off.
        case pause
        /// Stop hearing and saying.
        case stop
    }

    /// What the assistant says while it thinks, in its own voice, one a turn at most.
    static let holdingLines = [
        "One sec.",
        "Let me check.",
        "Okay, give me a moment.",
        "Hmm, let me see.",
        "Okay, let me think.",
        "Bear with me a second.",
    ]
    /// How long after the person's words went a holding line is said, if nothing has been.
    static let holdingDelay: TimeInterval = 1.5
    /// Words that only ever stop someone talking. A word or two of them alone always cuts
    /// in, though the voice said them this turn, so the person can always stop it.
    static let stoppingWords: Set<String> = ["stop", "wait", "no", "hold", "hang", "on"]

    private(set) var phase: Phase = .listening
    /// Whether the microphone is muted. Nothing heard while it is counts.
    private(set) var isMuted = false
    /// Whether the call is on hold: nothing is heard or said until it comes off.
    private(set) var isHeld = false
    /// The person's turn while it is open.
    private(set) var utterance = UtteranceEnd()
    /// What the assistant is busy with while the call waits for it.
    private(set) var activity: AssistantActivity?
    /// The reply's sentences handed to the voice, in order.
    private(set) var sentences: [String] = []
    /// How many of `sentences` have been said to their end.
    private(set) var saidCount = 0
    /// This turn's holding line, once one has been said.
    private(set) var holdingLine: String?
    /// Whether the holding line is being said now. It is always the first thing said in a
    /// turn, so the first sentence said to its end while it is, is it.
    private(set) var isHolding = false
    /// Whether the person cut in before the reply was all said.
    private(set) var isCut = false
    /// Whether today's voice is used up, so every reply for the rest of the call shows in
    /// words instead.
    private(set) var isVoiceUsedUp = false

    private(set) var isClosingCall = false

    private var waitingSince: Date?
    private var reply = ""
    private var isReplyFinished = false
    private var splitter = SpokenSentences()
    /// Which holding line comes next. They take turns, so none is said twice running, and
    /// the next call starts where this one left off.
    private(set) var nextHoldingLine: Int
    /// The words of the last thing heard that was only the voice's echo, since the words
    /// last started afresh. A turn the person cuts in with starts after them.
    private var echo: [String] = []

    /// `firstHoldingLine`, an index of `holdingLines`, picks where the holding lines start,
    /// so each call can start on a different one.
    init(firstHoldingLine: Int = 0) {
        nextHoldingLine = firstHoldingLine % Self.holdingLines.count
    }

    /// The holding lines in the order this call says them, so the first one a wait needs is
    /// the first one readied.
    var holdingLinesInTurn: [String] {
        Self.holdingLines.indices.map { Self.holdingLines[(nextHoldingLine + $0) % Self.holdingLines.count] }
    }

    mutating func handle(_ input: Input) -> Effect {
        switch (phase, input) {
        case (.ended, _):
            return .none
        case (_, .hungUp):
            phase = .ended
            return .stop
        case (_, .muted(let isMuted)):
            guard isMuted != self.isMuted else {
                return .none
            }
            self.isMuted = isMuted
            return .mute(isMuted)
        case (_, .held(let isHeld)):
            guard isHeld != self.isHeld else {
                return .none
            }
            self.isHeld = isHeld
            return isHeld ? pause() : resume()
        case (.failed, .tapped):
            return listenAgain()
        case (.failed, _), (_, .tapped):
            return .none
        case (_, .failed(let reason)):
            phase = .failed(reason)
            return .stop
        case (_, .voiceUsedUp):
            return useUpTheVoice()
        case (.listening, .began):
            return .listen
        case (_, .heard) where isMuted || isHeld:
            return .none
        case (_, .tick) where isHeld:
            return .none
        case (_, .saidSentence) where isHeld:
            return .none
        case (.listening, .heard(let text, let moment)):
            utterance.hear(withoutEcho(text), at: moment)
            return .none
        case (.waiting, .heard(let text, let moment)), (.speaking, .heard(let text, let moment)):
            return cutIn(text, at: moment)
        case (.listening, .tick(let moment)):
            return endTurnIfOver(at: moment)
        case (.waiting, .tick(let moment)):
            return holdIfQuiet(at: moment)
        case (.waiting, .reply(let text, let isFinished)), (.speaking, .reply(let text, let isFinished)):
            reply = text
            isReplyFinished = isFinished
            // On hold it is kept, and said once the call comes off.
            return isHeld ? .none : sayWhatIsReady(isFinished ? .finished : .arriving)
        case (.waiting, .working(let busy)), (.speaking, .working(let busy)):
            activity = busy
            // A tool keeps the reply waiting, so whatever it has said so far is said now.
            return busy == nil || isHeld ? .none : sayWhatIsReady(.paused)
        case (.speaking, .saidSentence):
            if isHolding {
                isHolding = false
            } else {
                saidCount = min(saidCount + 1, sentences.count)
            }
            return goOnAfterSaying()
        default:
            return .none
        }
    }

    // MARK: - The person's turn

    private mutating func endTurnIfOver(at moment: Date) -> Effect {
        guard utterance.isOver(at: moment) else {
            return .none
        }
        let words = utterance.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if UtteranceEnd.words(in: words).allSatisfy({ $0 == "stop" }) {
            phase = .ended
            return .stop
        }
        wait(since: moment)
        isClosingCall = Self.isFarewell(words)
        return .send(words)
    }

    /// Words heard while the assistant speaks or thinks. Real words stop it at once and
    /// open the person's turn with them. Words the voice has said this turn are its echo.
    private mutating func cutIn(_ text: String, at moment: Date) -> Effect {
        let heard = UtteranceEnd.words(in: text)
        guard !heard.isEmpty else {
            return .none
        }
        let said = Set((sentences + [holdingLine].compactMap { $0 }).flatMap(UtteranceEnd.words(in:)))
        let isStopping = heard.count <= 2 && heard.allSatisfy { Self.stoppingWords.contains($0) }
        if !isStopping, heard.allSatisfy({ said.contains($0) }) {
            echo = heard
            return .none
        }
        phase = .listening
        isClosingCall = false
        isCut = true
        isHolding = false
        utterance = UtteranceEnd()
        utterance.hear(withoutEcho(text), at: moment)
        return .interrupt
    }

    /// What was heard, after any echo it starts with.
    private func withoutEcho(_ text: String) -> String {
        guard !echo.isEmpty, UtteranceEnd.words(in: text).starts(with: echo) else {
            return text
        }
        return UtteranceEnd.dropping(echo.count, wordsFrom: text)
    }

    private mutating func listenAgain() -> Effect {
        phase = .listening
        utterance = UtteranceEnd()
        echo = []
        isHolding = false
        return .listen
    }

    // MARK: - The assistant's turn

    private mutating func wait(since moment: Date) {
        phase = .waiting
        waitingSince = moment
        utterance = UtteranceEnd()
        echo = []
        activity = nil
        sentences = []
        saidCount = 0
        holdingLine = nil
        isHolding = false
        isCut = false
        reply = ""
        isReplyFinished = false
        splitter = SpokenSentences()
    }

    /// A holding line, once a turn, when nothing of the reply has come a moment and a half
    /// after the words went.
    private mutating func holdIfQuiet(at moment: Date) -> Effect {
        guard
            holdingLine == nil,
            !isClosingCall,
            !isVoiceUsedUp,
            sentences.isEmpty,
            reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let waitingSince,
            moment.timeIntervalSince(waitingSince) >= Self.holdingDelay
        else {
            return .none
        }
        let line = Self.holdingLines[nextHoldingLine]
        nextHoldingLine = (nextHoldingLine + 1) % Self.holdingLines.count
        holdingLine = line
        isHolding = true
        phase = .speaking
        return .hold(line)
    }

    /// Nothing more is said aloud. A reply already all in shows at once and the turn opens
    /// again. One still arriving shows as it comes, and the microphone stays on.
    private mutating func useUpTheVoice() -> Effect {
        isVoiceUsedUp = true
        guard phase == .speaking || phase == .waiting else {
            return .none
        }
        saidCount = sentences.count
        isHolding = false
        if isReplyFinished {
            return finishReply()
        }
        phase = .waiting
        return .interrupt
    }

    private mutating func sayWhatIsReady(_ progress: SpokenSentences.Progress) -> Effect {
        let ready = splitter.take(from: reply, progress)
        if isVoiceUsedUp {
            // Each sentence shows the moment it is whole, as if it had been said.
            sentences += ready
            saidCount = sentences.count
            return isReplyFinished ? finishReply() : .none
        }
        guard ready.isEmpty else {
            sentences += ready
            phase = .speaking
            return .say(ready)
        }
        return goOnAfterSaying()
    }

    /// Once everything handed to the voice is said: the turn opens again when the reply
    /// is all in, and the assistant is thinking until then.
    private mutating func goOnAfterSaying() -> Effect {
        guard !isHolding, saidCount >= sentences.count else {
            return .none
        }
        if isReplyFinished {
            return finishReply()
        }
        phase = .waiting
        return .none
    }

    /// A closing phrase must be the whole turn, never "thanks, can you also ...".
    static func isFarewell(_ text: String) -> Bool {
        var words = UtteranceEnd.words(in: text)
        while let last = words.last, ["corey", "cory", "denise"].contains(last) { words.removeLast() }
        if let first = words.first, ["okay", "ok", "alright"].contains(first) { words.removeFirst() }
        let phrase = words.joined(separator: " ")
        return ["thanks", "thank you", "thanks so much", "thank you so much", "thanks a lot",
                "goodbye", "good bye", "bye", "bye bye", "see you later", "talk to you later",
                "thanks goodbye", "thank you goodbye", "thanks bye", "thank you bye",
                "that's all", "that is all", "that's all thanks", "that's all thank you"].contains(phrase)
    }

    private mutating func finishReply() -> Effect {
        guard isClosingCall else { return listenAgain() }
        // Even an empty/model-card-only reply gets a spoken farewell.
        if sentences.isEmpty, !isVoiceUsedUp {
            sentences = ["Goodbye!"]
            phase = .speaking
            return .say(sentences)
        }
        phase = .ended
        return .stop
    }

    // MARK: - On hold

    /// The voice stops at once. A holding line it cut off is not said again: the turn has
    /// had its one.
    private mutating func pause() -> Effect {
        isHolding = false
        return .pause
    }

    /// A turn that was open starts afresh, since what was said before the hold is stale. A
    /// reply carries on from the sentence the hold cut off, then says whatever arrived
    /// meanwhile.
    private mutating func resume() -> Effect {
        switch phase {
        case .listening:
            return listenAgain()
        case .waiting, .speaking:
            let progress: SpokenSentences.Progress = isReplyFinished ? .finished : activity == nil ? .arriving : .paused
            sentences += splitter.take(from: reply, progress)
            if isVoiceUsedUp {
                saidCount = sentences.count
            }
            guard saidCount < sentences.count else {
                return goOnAfterSaying()
            }
            phase = .speaking
            return .say(Array(sentences[saidCount...]))
        case .ended, .failed:
            return .none
        }
    }
}

