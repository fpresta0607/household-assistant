// A person's choice to share where their iPhone is: with whom, until when, and whether it
// is paused. Each person makes it on their own iPhone, and wherever it is kept, none at
// all means off, which is where everybody starts.

import Foundation

struct LocationSharing: Codable, Equatable, Sendable {
    var audience: LocationAudience
    var span: LocationSpan
    /// When it stops by itself. Nil for always.
    var until: Date?
    var isPaused = false

    init(audience: LocationAudience, span: LocationSpan, from start: Date, calendar: Calendar) {
        self.audience = audience
        self.span = span
        until = span.end(from: start, calendar: calendar)
    }

    func isOver(at now: Date) -> Bool {
        until.map { now >= $0 } ?? false
    }

    /// Whether the phone tells its gateway where it is now.
    func isSending(at now: Date) -> Bool {
        !isPaused && !isOver(at: now)
    }

    /// When it ends, as a person would say it.
    var endWords: String {
        guard let until else {
            return "until you stop it"
        }
        return span == .tonight ? "until midnight" : "until \(until.formatted(date: .omitted, time: .shortened))"
    }
}
