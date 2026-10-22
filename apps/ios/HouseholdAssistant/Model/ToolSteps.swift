// What the working line in the typing bubble says while this phone's assistant uses its
// tools, each step held long enough to read. A tool done in a few milliseconds flashed its
// line and was gone; now each step stays at least `held` once it shows, and steps that come
// while one is held wait their turn, in order, rather than flash past. The thinking in
// between, the typing dots, shows only once nothing waits. The reply never waits on them:
// it takes the typing bubble's place the moment it is ready.

import Foundation

struct ToolSteps: Equatable, Sendable {
    /// The least time a step stays on the line once it shows.
    static let held: TimeInterval = 0.5

    /// What the line says now: a step, or nil for the dots.
    private(set) var shown: AssistantActivity?
    /// When the shown step came on the line.
    private(set) var shownAt: Date?
    /// The steps that began while the shown one was held, oldest first.
    private var waiting: [AssistantActivity] = []
    /// What the assistant is doing now, nil while it thinks.
    private var current: AssistantActivity?

    /// The assistant began a step, or finished one with nil, at `now`.
    mutating func follow(_ activity: AssistantActivity?, at now: Date) {
        current = activity
        if isHeld(at: now) {
            if let activity, activity != shown, activity != waiting.last {
                waiting.append(activity)
            }
        } else {
            show(activity, at: now)
        }
    }

    /// When the shown step will have been held long enough to give way to what is waiting,
    /// or nil when nothing waits for it.
    var nextChange: Date? {
        guard let shownAt, shown != nil, !waiting.isEmpty || current != shown else {
            return nil
        }
        return shownAt.addingTimeInterval(Self.held)
    }

    /// Moves on to the next step waiting, or to what the assistant is doing now, once the
    /// shown step has been held long enough.
    mutating func advance(at now: Date) {
        guard !isHeld(at: now) else {
            return
        }
        if waiting.isEmpty {
            show(current, at: now)
        } else {
            show(waiting.removeFirst(), at: now)
        }
    }

    private func isHeld(at now: Date) -> Bool {
        guard shown != nil, let shownAt else {
            return false
        }
        return now.timeIntervalSince(shownAt) < Self.held
    }

    private mutating func show(_ activity: AssistantActivity?, at now: Date) {
        guard activity != shown else {
            return
        }
        shown = activity
        shownAt = activity == nil ? nil : now
    }
}
