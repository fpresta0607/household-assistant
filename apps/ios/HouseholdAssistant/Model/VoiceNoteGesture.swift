// Recording a voice note the way Telegram does it, as a value with no I/O: the note
// starts the moment the microphone is touched, slide left to cancel, slide up to lock for
// hands-free, let go to send. A tap, too short to have said anything, keeps the note
// recording hands-free, as a locked one: the microphone only ever makes voice notes. A
// locked note is sent with the send button, or stopped to listen back to first, then sent
// or thrown away. The view reports the finger and the clock; the recorder does what the
// phase says.

import Foundation

struct VoiceNoteGesture: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case send(durationMs: Int)
        case cancelled
        /// Stopped or sent too soon after it started to have said anything.
        case tooShort
    }

    enum Phase: Equatable, Sendable {
        case idle
        case holding
        case locked
        /// Stopped and kept, to be listened back to before it is sent or thrown away.
        case reviewing(durationMs: Int)
        case finished(Outcome)
    }

    /// How far left the finger goes to cancel, and how far up to lock, in points.
    static let cancelDistance: Double = 120
    static let lockDistance: Double = 80
    static let shortest: TimeInterval = 0.5
    /// A note is cut here, as Telegram's are, so one never runs away.
    static let longest: TimeInterval = 15 * 60

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    /// 0...1, how far towards cancelling the finger has slid, for the hint to fade in.
    private(set) var cancelProgress: Double = 0
    /// 0...1, how far towards locking.
    private(set) var lockProgress: Double = 0

    var isRecording: Bool {
        phase == .holding || phase == .locked
    }

    var isReviewing: Bool {
        if case .reviewing = phase {
            return true
        }
        return false
    }

    mutating func press(at moment: Date) {
        guard phase == .idle else {
            return
        }
        phase = .holding
        startedAt = moment
    }

    /// A note with no finger on it, already locked: the widget's microphone opens the app
    /// straight into one.
    mutating func startLocked(at moment: Date) {
        guard phase == .idle else {
            return
        }
        phase = .locked
        startedAt = moment
    }

    /// The finger's offset from where it pressed: negative x is left, negative y is up.
    /// Whichever way it has gone further is the one that counts, so a slide to cancel
    /// that drifts up never locks, and a slide up that drifts left never cancels.
    mutating func drag(x: Double, y: Double) {
        guard phase == .holding else {
            return
        }
        let left = max(-x, 0)
        let up = max(-y, 0)
        cancelProgress = left > up ? min(left / Self.cancelDistance, 1) : 0
        lockProgress = up >= left ? min(up / Self.lockDistance, 1) : 0
        if cancelProgress >= 1 {
            phase = .finished(.cancelled)
        } else if lockProgress >= 1 {
            phase = .locked
        }
    }

    /// The finger lifting: a hold sends what was said, and a tap keeps recording, locked.
    mutating func release(at moment: Date) {
        guard phase == .holding else {
            return
        }
        if elapsed(at: moment) < Self.shortest {
            phase = .locked
            cancelProgress = 0
            lockProgress = 0
        } else {
            finish(at: moment)
        }
    }

    /// The send button: a locked note goes as it is, a stopped one as it was kept.
    mutating func send(at moment: Date) {
        switch phase {
        case .locked:
            finish(at: moment)
        case .reviewing(let durationMs):
            phase = .finished(.send(durationMs: durationMs))
        default:
            break
        }
    }

    /// The stop button of a locked note: keep what was said, to listen back to.
    mutating func stop(at moment: Date) {
        guard phase == .locked else {
            return
        }
        let duration = elapsed(at: moment)
        phase = duration < Self.shortest
            ? .finished(.tooShort)
            : .reviewing(durationMs: Self.milliseconds(duration))
    }

    /// The bin of a locked or stopped note.
    mutating func discard() {
        guard isRecording || isReviewing else {
            return
        }
        phase = .finished(.cancelled)
    }

    /// The clock moving on while recording; a note that reaches the longest is sent.
    mutating func tick(at moment: Date) {
        guard isRecording, let startedAt, moment.timeIntervalSince(startedAt) >= Self.longest else {
            return
        }
        phase = .finished(.send(durationMs: Int(Self.longest * 1000)))
    }

    /// Back to idle after the outcome has been acted on.
    mutating func reset() {
        self = VoiceNoteGesture()
    }

    func elapsed(at moment: Date) -> TimeInterval {
        startedAt.map { min(moment.timeIntervalSince($0), Self.longest) } ?? 0
    }

    private mutating func finish(at moment: Date) {
        let duration = elapsed(at: moment)
        phase = duration < Self.shortest
            ? .finished(.tooShort)
            : .finished(.send(durationMs: Self.milliseconds(duration)))
    }

    private static func milliseconds(_ duration: TimeInterval) -> Int {
        Int((duration * 1000).rounded())
    }

    /// "0:04", "1:05": how long a note is, the way a voice note shows it.
    static func clock(milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
