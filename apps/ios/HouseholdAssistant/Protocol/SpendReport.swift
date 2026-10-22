// The household's month as `household-app.spend` answers it, the same on both gateways:
// what the one OpenRouter key they share spent since the 1st in the household's own days,
// its total by the end of each day, and a line each for Corey, Denise and whatever else
// used the key, which add up to the total to the cent. The box adds it up every ten
// minutes from OpenRouter's own usage of the key and each gateway's own ledger
// (scripts/household-spend.py). Dollars only, never the key.

import Foundation

struct SpendReport: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        /// `2026-10-07`, in the household's own days.
        let day: String
        /// The month's total by the end of that day.
        let spent: Double
    }

    struct Line: Codable, Equatable, Sendable, Identifiable {
        /// `corey`, `denise`, or `other` for the rest of what the key spent.
        let id: String
        /// `Corey`, or `Other use of the key`.
        let name: String
        let amount: Double

        /// An assistant's line rather than the rest of the key's.
        var isAssistant: Bool {
            id != "other"
        }
    }

    /// `2026-10`.
    let month: String
    /// When the box last read the key, in milliseconds since 1970.
    let at: Int
    let total: Double
    /// The 1st through today, oldest first.
    let days: [Day]
    /// Corey, Denise, then the rest.
    let lines: [Line]
    /// `2026-11-01`.
    let resetsOn: String

    var updatedAt: Date {
        Date(timeIntervalSince1970: Double(at) / 1000)
    }

    /// Two missed ten-minute readings mean the source itself needs attention,
    /// even if the phone successfully downloaded the old report again.
    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > 20 * 60
    }
}

