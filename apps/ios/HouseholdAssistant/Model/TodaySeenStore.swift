// Where the phone keeps when its person last saw the whole Today card, across launches, so
// it stays a slim banner for the rest of that day.
//
// A protocol because the phone keeps it in its settings and the tests keep it in memory.

import Foundation

@MainActor
protocol TodaySeenStore: AnyObject {
    /// When the whole card was last seen or checked off. Nil until it ever has been.
    var todaySeenAt: Date? { get set }
    /// The day's verse was actually visible when the card was left or checked off.
    var todaySeenVerseDay: String? { get set }
}
