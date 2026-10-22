// Runs a call: performs what the `TalkSession` loop decides, follows the reply as it
// streams into this phone's own thread, and keeps the one number the ring round the face
// moves to. The microphone stays on for the whole call, unless the person mutes it. The
// reply is said in the assistant's own voice, spoken by its gateway (TalkVoice), through
// the microphone's own audio engine, so echo cancellation keeps the phone from hearing
// itself and the person can talk over it. With reading replies aloud off in Accessibility,
// each sentence counts as said the moment it is ready, and no holding line is said.
//
// Each turn goes to the thread as a message, marked as said on a call so the assistant
// answers it to be heard, and so it has the call in its own conversation. Once the call
// ends, the gateway folds those messages and their replies into one call entry with the
// words alone, which the thread shows as one row.
//
// It is a real iOS call (SystemCall), placed once the microphone is allowed. iOS hands it
// the sound, and the microphone and the voice run only while the sound is the call's and
// the call is not on hold. Where the call stands, calling, connected, reconnecting while the
// gateway's link is down, on hold or ended, comes from iOS and the link together
// (CallState), and a turn goes only while it is connected. The call lives above every
// screen (AppModel), so it carries on behind the call bar while the person moves round the
// app, and once it has ended it says so for a moment before it closes.

import Foundation
import Observation

@MainActor
@Observable
final class TalkViewModel: Identifiable {
    private(set) var session: TalkSession
    /// Where the call stands with iOS and the gateway.
    private(set) var state = CallState()
    /// 0...1, smoothed. The microphone while the person talks, the voice while it speaks.
    private(set) var level: Double = 0
    /// Where the call's sound goes, for the speaker button.
    let audio: CallAudio
    /// Called a moment after the call has ended, to close it.
    @ObservationIgnored var onClosed: (() -> Void)?

    @ObservationIgnored private let room: RoomModel
    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let isReadingAloud: Bool
    @ObservationIgnored private let voice: TalkVoice
    @ObservationIgnored private let listener: SpeechListener
    @ObservationIgnored private let holdingLines: HoldingLines
    @ObservationIgnored private let systemCall: SystemCall
    @ObservationIgnored private let startedAt = Date()
    /// The call, as its entry is kept under once it ends.
    @ObservationIgnored private let callId = UUID().uuidString.lowercased()
    /// The message the person's last turn went out as, once the thread has it.
    @ObservationIgnored private var askedId: String?
    /// Every turn the person said on this call, in order.
    @ObservationIgnored private var asked: [String] = []
    /// When the call's first words went, and when the first words of their reply came,
    /// for the call's record.
    @ObservationIgnored private var firstSentAt: Date?
    @ObservationIgnored private var firstReplyAt: Date?
    @ObservationIgnored private var envelope = LevelEnvelope()
    @ObservationIgnored private var microphoneLevel: Double = 0
    /// Whether the call wants the microphone, which is from the first listen until the call
    /// ends or fails.
    @ObservationIgnored private var isHearing = false
    /// Whether Speech Recognition and the microphone are allowed.
    @ObservationIgnored private var isAllowed = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var startingToHear: Task<Void, Never>?
    @ObservationIgnored private var preparingLines: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    /// The reply and the activity as last handed to the session, so each change is fed once.
    @ObservationIgnored private var fedReply: (text: String, isFinished: Bool)?
    @ObservationIgnored private var fedActivity: AssistantActivity?

    /// How long an ended call says so before it closes, as the Phone app does.
    private static let endedPause = Duration.milliseconds(1500)
    /// Where the next call's holding lines start, kept between calls.
    private static let nextHoldingLineKey = "talk-next-holding-line"

    init(
        room: RoomModel,
        connection: GatewayConnection,
        voice: TalkVoice,
        holdingLines: HoldingLines,
        isReadingAloud: Bool,
        assistantName: String
    ) {
        self.room = room
        self.connection = connection
        self.voice = voice
        self.holdingLines = holdingLines
        self.isReadingAloud = isReadingAloud
        listener = SpeechListener(voice: voice)
        systemCall = SystemCall(callerName: assistantName)
        audio = CallAudio()
        // Each call starts on the holding line after the last one said, so a call never
        // opens with the line the one before it ended on. The first call starts anywhere.
        session = TalkSession(
            firstHoldingLine: UserDefaults.standard.object(forKey: Self.nextHoldingLineKey) as? Int
                ?? Int.random(in: TalkSession.holdingLines.indices)
        )
        listener.onTranscript = { [weak self] in self?.feed(.heard($0, at: Date())) }
        listener.onLevel = { [weak self] in self?.microphoneLevel = $0 }
        listener.onFailure = { [weak self] in self?.feed(.failed($0)) }
        voice.onSentence = { [weak self] in
            self?.feed(.saidSentence)
        }
        voice.onUsedUp = { [weak self] in self?.feed(.voiceUsedUp) }
        voice.onFailure = { [weak self] in self?.feed(.failed($0)) }
        systemCall.onAudio = { [weak self] in self?.follow(.audio(isActive: $0)) }
        systemCall.onMuted = { [weak self] in self?.feed(.muted($0)) }
        systemCall.onHeld = { [weak self] in self?.follow(.held($0)) }
        systemCall.onEnded = { [weak self] in self?.finish() }
        systemCall.onRefused = { [weak self] in self?.feed(.failed($0)) }
        audio.onInterruption = { [weak self] in self?.follow(.interrupted($0)) }
    }

    /// Places the call. It listens as soon as the microphone is allowed and iOS has handed
    /// it the sound.
    func begin() {
        // A link waiting out the delay before its next try, as after the gateway restarted,
        // tries now rather than leaving the call calling.
        connection.retryNow()
        audio.start()
        followLink()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        if isReadingAloud {
            let holdingLines = self.holdingLines
            let inTurn = session.holdingLinesInTurn
            preparingLines = Task {
                await holdingLines.prepare(inTurn)
            }
        }
        feed(.began)
    }

    func tapped() {
        feed(.tapped)
    }

    /// Mute, through iOS, so the Lock Screen and AirPods agree. It is fed back from there.
    func toggleMute() {
        systemCall.setMuted(!session.isMuted)
    }

    /// The Speaker button: the speaker or the earpiece.
    func toggleSpeaker() {
        audio.toggleSpeaker()
    }

    /// End Call: iOS ends it everywhere, and then it ends here.
    func hangUp() {
        systemCall.end()
    }

    /// The call ended, from its screen, the Lock Screen, AirPods, the car or the word
    /// "stop". Everything stops, the gateway folds the call into one entry, and the call
    /// says it has ended for a moment before it closes.
    private func finish() {
        guard state.stage != .ended else {
            return
        }
        feed(.hungUp)
        follow(.ended)
        ticker?.cancel()
        sending?.cancel()
        preparingLines?.cancel()
        level = 0
        audio.stop()
        UserDefaults.standard.set(session.nextHoldingLine, forKey: Self.nextHoldingLineKey)
        logCall()
        closing = Task { [weak self] in
            try? await Task.sleep(for: Self.endedPause)
            self?.onClosed?()
        }
    }

    /// The call ended: the gateway folds its turns and their replies into one call entry,
    /// timed from when it connected, as its time on the screen was, and logs how the call
    /// came up.
    private func logCall() {
        let room = self.room
        let turns = RoomCall.turnIds(asked: asked, in: room.thread(.direct), assistant: room.me?.assistant)
        let (callId, startedAt, endedAt) = (self.callId, state.connectedAt ?? self.startedAt, Date())
        let setup = CallSetup(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            tappedAt: self.startedAt,
            state: state,
            placement: systemCall.placement,
            firstSentAt: firstSentAt,
            firstReplyAt: firstReplyAt
        )
        Task {
            await room.logCall(id: callId, startedAt: startedAt, endedAt: endedAt, turns: turns, setup: setup)
        }
    }

    // MARK: - The call with iOS and the gateway

    /// Keeps the call in step with the gateway's link.
    private func followLink() {
        guard state.stage != .ended else {
            return
        }
        let isUp = withObservationTracking {
            connection.state == .connected
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followLink()
            }
        }
        follow(.link(isUp: isUp))
    }

    /// Moves the call along, tells iOS once it has connected, and runs the microphone and the
    /// voice to match: on hold, the assistant stops and the turn waits.
    private func follow(_ input: CallState.Input) {
        let before = state
        state.handle(input, at: Date())
        if before.connectedAt == nil, let connectedAt = state.connectedAt {
            systemCall.connected(at: connectedAt)
        }
        // The route is set on the sound iOS has just made active, before the engine runs on it.
        if input == .audio(isActive: true) {
            audio.soundBecameActive()
        }
        // The engine runs again before anything is said on it.
        runMicrophone()
        let isOnHold = state.stage == .onHold
        if isOnHold != session.isHeld {
            feed(.held(isOnHold))
        }
    }

    /// Runs the microphone, and with it the engine the voice plays on, while the call wants
    /// to hear and the sound is the call's.
    private func runMicrophone() {
        let shouldRun = isHearing && isAllowed && state.canHear
        if shouldRun, !listener.isRunning {
            microphoneLevel = 0
            listener.start()
        } else if !shouldRun, listener.isRunning {
            listener.stop()
            microphoneLevel = 0
        }
    }

    // MARK: - The loop

    private func tick() {
        let now = Date()
        // A turn goes only over a link that is up: until it is, what the person says waits,
        // and so does the holding line.
        if state.stage == .connected {
            feed(.tick(now))
        }
        followReply()
        let target: Double
        switch session.phase {
        case .listening:
            target = session.isMuted || !state.canHear ? 0 : microphoneLevel
        case .speaking:
            target = state.canHear ? voice.level : 0
        case .waiting, .ended, .failed:
            target = 0
        }
        level = envelope.feed(target)
    }

    /// Hands the session what the thread now says about the person's last turn: whether
    /// it was refused, what the assistant is busy with, and its reply so far.
    private func followReply() {
        guard session.phase == .waiting || session.phase == .speaking, let askedId else {
            return
        }
        let thread = room.thread(.direct)
        if case .failed(let reason) = thread.messages.first(where: { $0.id == askedId })?.status {
            feed(.failed(reason))
            return
        }
        let activity = room.activity(in: .direct)
        if activity != fedActivity {
            fedActivity = activity
            feed(.working(activity))
        }
        guard let assistant = room.me?.assistant, let reply = thread.reply(to: askedId, from: assistant) else {
            return
        }
        if case .failed(let reason) = reply.status {
            feed(.failed(reason))
            return
        }
        if firstReplyAt == nil, !reply.text.isEmpty {
            firstReplyAt = Date()
        }
        let isFinished = reply.status != .streaming
        if fedReply?.text != reply.text || fedReply?.isFinished != isFinished {
            fedReply = (reply.text, isFinished)
            feed(.reply(reply.text, isFinished: isFinished))
        }
    }

    private func feed(_ input: TalkSession.Input) {
        switch session.handle(input) {
        case .none:
            break
        case .listen:
            if isHearing {
                listener.beginTurn()
            } else {
                startHearing()
            }
        case .send(let words):
            listener.beginTurn()
            send(words)
        case .say(let sentences):
            if isReadingAloud {
                voice.say(sentences)
            } else {
                for _ in sentences {
                    feed(.saidSentence)
                }
            }
        case .hold(let line):
            // A line not on the phone yet is passed over, as if it had been said.
            if isReadingAloud, let file = holdingLines.file(for: line) {
                voice.hold(file)
            } else {
                feed(.saidSentence)
            }
        case .interrupt, .pause:
            voice.stop()
        case .mute(let isMuted):
            listener.isMuted = isMuted
            if isMuted {
                microphoneLevel = 0
            }
        case .stop:
            stopHearing()
            voice.stop()
            // The word "stop" said on its own hangs up. Hung up already, this does nothing.
            if session.phase == .ended {
                systemCall.end()
            }
        }
    }

    /// Asks for the microphone the first time, then places the call with iOS, and hears once
    /// iOS hands the call its sound.
    private func startHearing() {
        isHearing = true
        guard !isAllowed else {
            hearOnTheCall()
            return
        }
        startingToHear = Task {
            let refusal = await SpeechListener.requestAccess()
            guard !Task.isCancelled, isHearing else {
                return
            }
            if let refusal {
                feed(.failed(refusal))
            } else {
                isAllowed = true
                hearOnTheCall()
            }
        }
    }

    /// A call iOS already has carries on as it is.
    private func hearOnTheCall() {
        systemCall.start()
        runMicrophone()
    }

    private func stopHearing() {
        startingToHear?.cancel()
        isHearing = false
        listener.stop()
    }

    /// Sends the person's words to their own thread, where they show like anything typed.
    private func send(_ words: String) {
        askedId = nil
        fedReply = nil
        fedActivity = nil
        firstSentAt = firstSentAt ?? Date()
        sending = Task {
            guard let person = room.me?.person else {
                feed(.failed(ErrorText.describe(GatewayConnectionError.notConnected)))
                return
            }
            await room.send(words, in: .direct, isCall: true)
            guard !Task.isCancelled else {
                return
            }
            guard let sent = room.thread(.direct).messages.last(where: { $0.author == person }) else {
                feed(.failed(ErrorText.describe(GatewayConnectionError.notConnected)))
                return
            }
            askedId = sent.id
            asked.append(sent.id)
        }
    }
}
