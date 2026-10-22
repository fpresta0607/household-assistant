// Where a call with the assistant stands, as the Phone app shows it: Calling until iOS has
// handed the call its sound and the gateway's link is up, then connected, with the time
// running from that moment, Reconnecting while the link is down, On Hold while iOS has the
// sound for something else, and Ended.
//
// iOS hands the sound over once CallKit has the call (SystemCall), and takes it away for a
// phone call the person holds ours for, or for a moment for Siri or an alarm. Until it is
// back the call is on hold: the microphone is off and nothing is said (TalkSession). A
// link that drops only stops turns from going. The microphone stays on, and what the
// person says goes once the link is back.
//
// The call taps as it moves into each stage, wherever it shows (CallStageHaptic): calling,
// connected, reconnecting and ended. Going on hold does not, since the phone is busy with
// another call then. A call first seen already under way, as when the call bar comes up
// over one, does not tap either: that is not news. Pure: moments in, so every rule is a
// plain test.

import Foundation

struct CallState: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case calling
        case connected
        case reconnecting
        case onHold
        case ended
    }

    enum Input: Equatable, Sendable {
        /// iOS made the call's sound active, or took it away.
        case audio(isActive: Bool)
        /// The link to the gateway came up, or went down.
        case link(isUp: Bool)
        /// iOS put the call on hold for a phone call the person took, or took it off.
        case held(Bool)
        /// Siri, an alarm or another app took the sound for a moment, or gave it back.
        case interrupted(Bool)
        /// The call ended, from wherever it was ended.
        case ended
    }

    /// What the person feels as the call moves.
    enum Haptic: Equatable, Sendable {
        case calling
        case connected
        case reconnecting
        case ended
    }

    private(set) var stage = Stage.calling
    /// When the call first connected, which its time counts from and iOS is told of once.
    private(set) var connectedAt: Date?
    /// When the call ended.
    private(set) var endedAt: Date?
    /// When the gateway's link was first up during the call, for its record.
    private(set) var linkUpAt: Date?
    /// When iOS first handed the call its sound, for its record.
    private(set) var soundAt: Date?

    private var isAudioActive = false
    private var isLinkUp = false
    private var isHeld = false
    private var isInterrupted = false

    mutating func handle(_ input: Input, at moment: Date) {
        guard stage != .ended else {
            return
        }
        switch input {
        case .audio(let isActive):
            isAudioActive = isActive
            // Sound handed back is the call's again, whatever had taken it. An interruption
            // does not always say when it is over.
            if isActive {
                isInterrupted = false
                soundAt = soundAt ?? moment
            }
        case .link(let isUp):
            isLinkUp = isUp
            if isUp {
                linkUpAt = linkUpAt ?? moment
            }
        case .held(let isHeld):
            self.isHeld = isHeld
        case .interrupted(let isInterrupted):
            self.isInterrupted = isInterrupted
        case .ended:
            stage = .ended
            endedAt = moment
            return
        }
        if connectedAt == nil, canHear, isLinkUp {
            connectedAt = moment
        }
        if connectedAt == nil {
            stage = .calling
        } else if !canHear {
            stage = .onHold
        } else {
            stage = isLinkUp ? .connected : .reconnecting
        }
    }

    /// Whether the microphone may run and the voice play: the sound is the call's and the
    /// call is not on hold. Before it connects as well, so what the person says while the
    /// link comes up is heard, and goes once it is.
    var canHear: Bool {
        stage != .ended && isAudioActive && !isHeld && !isInterrupted
    }

    /// What the line under the name says at `now`: "Calling…", how long the call has gone
    /// on, or "Call ended".
    func time(at now: Date) -> String {
        switch stage {
        case .calling:
            return "Calling\u{2026}"
        case .ended:
            return "Call ended"
        case .connected, .reconnecting, .onHold:
            return Self.clock(from: connectedAt ?? now, to: now)
        }
    }

    /// What the call bar says at `now`: the time while the call is connected, and otherwise
    /// what it is doing.
    func barWords(at now: Date) -> String {
        switch stage {
        case .reconnecting:
            return "Reconnecting\u{2026}"
        case .onHold:
            return "On hold"
        case .calling, .connected, .ended:
            return time(at: now)
        }
    }

    /// "1:24", or "1:02:09" past an hour.
    static func clock(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The tap for a call seen moving from `old` to `new`. A call seen for the first time,
    /// with no `old`, taps only as it starts.
    static func haptic(from old: Stage?, to new: Stage) -> Haptic? {
        guard new != old else {
            return nil
        }
        switch new {
        case .calling:
            return .calling
        case .onHold:
            return nil
        case .connected:
            return old == nil ? nil : .connected
        case .reconnecting:
            return old == nil ? nil : .reconnecting
        case .ended:
            return old == nil ? nil : .ended
        }
    }
}
