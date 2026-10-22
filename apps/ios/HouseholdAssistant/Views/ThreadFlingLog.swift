#if DEBUG
// What each scroll of the thread cost on the main thread, written to the thread's log
// (ThreadLog) once the scroll stops, for the fling test to read (FastFlingTests): every row
// built and measured and the slowest of them, the rows whose height came or changed after
// they were measured, each time the room worked out the rows again and handed them to the
// list, and the frames that came late, each with what was done in it. A late frame with
// nothing done in it was lost to drawing rather than to building. Rows are named by kind
// and length, never by a word of theirs.
// It runs only while a UI test reads the log (`-StewardThreadLog YES`), so the hitch tests
// measure the app without it.

import QuartzCore

@MainActor
final class ThreadFlingLog: NSObject {
    static let shared = ThreadFlingLog()

    /// A row built, or a pass of the room's, and what it took.
    private struct Built {
        let kind: String
        let milliseconds: Double
    }

    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var frames = 0
    private var built: [Built] = []
    private var builtThisFrame: [Built] = []
    private var lateFrames: [(milliseconds: Double, built: [Built])] = []
    private var lateFirstHeights: [String] = []
    private var resized: [String] = []
    private var passes: [Built] = []

    /// The person's finger started a scroll. One that starts while the last still glides
    /// goes on counting with it.
    func began() {
        guard ThreadLog.isShown, link == nil else {
            return
        }
        frames = 0
        built = []
        builtThisFrame = []
        lateFrames = []
        lateFirstHeights = []
        resized = []
        passes = []
        lastFrame = 0
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A row of `kind` was built and measured, which started at `start`.
    func built(_ kind: String, since start: CFTimeInterval) {
        guard link != nil else {
            return
        }
        let row = Built(kind: kind, milliseconds: (CACurrentMediaTime() - start) * 1000)
        built.append(row)
        builtThisFrame.append(row)
    }

    /// A row of `kind` took a height after it was measured: its first, or a new one.
    func drewLate(_ kind: String, isFirst: Bool) {
        guard link != nil else {
            return
        }
        if isFirst {
            lateFirstHeights.append(kind)
        } else {
            resized.append(kind)
        }
    }

    /// The room worked out the rows again, or handed them to the list, as `part`, which
    /// started at `start`.
    func passed(_ part: String, since start: CFTimeInterval) {
        guard link != nil else {
            return
        }
        let pass = Built(kind: part, milliseconds: (CACurrentMediaTime() - start) * 1000)
        passes.append(pass)
        builtThisFrame.append(pass)
    }

    /// The scroll stopped.
    func ended() {
        guard let link else {
            return
        }
        link.invalidate()
        self.link = nil
        let total = built.reduce(0) { $0 + $1.milliseconds }
        let slowest = built.sorted { $0.milliseconds > $1.milliseconds }.prefix(6).map(Self.text)
        let worst = lateFrames.sorted { $0.milliseconds > $1.milliseconds }.prefix(4).map { frame in
            "\(Int(frame.milliseconds)) ms [\(frame.built.map(Self.text).joined(separator: ", "))]"
        }
        let passing = Dictionary(grouping: passes, by: \.kind).sorted { $0.key < $1.key }.map { part, group in
            "\(part) \(group.count) in \(Int(group.reduce(0) { $0 + $1.milliseconds })) ms"
        }
        ThreadLog.note(
            "fling built \(built.count) rows in \(Int(total)) ms, slowest \(slowest.joined(separator: ", ")); "
                + "late first heights \(lateFirstHeights.count) \(Self.counted(lateFirstHeights)); "
                + "resized \(resized.count) \(Self.counted(resized)); room \(passing.joined(separator: ", ")); "
                + "late frames \(lateFrames.count) of \(frames), worst \(worst.joined(separator: "; "))"
        )
    }

    @objc private func frame(_ link: CADisplayLink) {
        if lastFrame > 0 {
            frames += 1
            let interval = link.timestamp - lastFrame
            if interval > (link.targetTimestamp - link.timestamp) * 1.5 {
                lateFrames.append((interval * 1000, builtThisFrame))
            }
        }
        lastFrame = link.timestamp
        builtThisFrame = []
    }

    private static func text(_ row: Built) -> String {
        "\(row.kind) \(Int(row.milliseconds.rounded()))"
    }

    /// "chart 3, voice note 2", most first.
    private static func counted(_ kinds: [String]) -> String {
        Dictionary(kinds.map { ($0, 1) }, uniquingKeysWith: +)
            .sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
    }

    /// What a row is, by kind and length.
    static func kind(of row: ThreadRow) -> String {
        switch row.content {
        case .older:
            return "older"
        case .hello:
            return "hello"
        case .typing:
            return "typing"
        case .shared:
            return "shared"
        case .look:
            return "look line"
        case .message(let content):
            let message = content.message
            if message.call != nil {
                return "call"
            }
            if message.media.contains(where: { $0.kind == .voice }) {
                return "voice note"
            }
            if message.media.contains(where: \.kind.isVisual) {
                return "photo"
            }
            if !message.media.isEmpty {
                return "file"
            }
            if message.text.contains("\"type\":\"chart\"") {
                return "chart"
            }
            if message.text.contains("```steward-card") {
                return "card"
            }
            return "text \(message.text.count)c"
        }
    }
}
#endif
