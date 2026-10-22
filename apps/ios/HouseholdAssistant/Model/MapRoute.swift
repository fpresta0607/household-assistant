// The way to a map card's place from where the phone is, as Apple Maps worked it out on
// the phone: the line to draw, how long it takes, how far, and the road it mostly takes.

import Foundation

struct MapRoute: Equatable, Sendable {
    let points: [MapPoint]
    let seconds: TimeInterval
    let metres: Double
    /// The road it mostly takes, as Apple Maps names it. Empty when it names none.
    let name: String

    /// Whole minutes, at least one.
    var minutes: Int {
        max(1, Int((seconds / 60).rounded(.down)))
    }

    func arrival(leaving now: Date) -> Date {
        now.addingTimeInterval(seconds)
    }
}
