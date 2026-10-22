// How a card writes a number: thousands with commas, at most two decimals, and money with
// cents only when there are some. Spelled out by hand rather than by a locale, so a card
// reads the same on every phone and in the tests.

import Foundation

enum CardNumber {
    /// "1,200", "42.5", "0.3".
    static func text(_ value: Double) -> String {
        let hundredths = Int64((abs(value) * 100).rounded())
        let whole = grouped(hundredths / 100)
        let fraction = hundredths % 100
        let sign = value < 0 && hundredths > 0 ? "-" : ""
        guard fraction > 0 else {
            return sign + whole
        }
        var decimals = String(format: "%02lld", fraction)
        if decimals.hasSuffix("0") {
            decimals.removeLast()
        }
        return sign + whole + "." + decimals
    }

    /// "$640", "$1,284.50", "-$12".
    static func money(_ value: Double, symbol: String = "$") -> String {
        let cents = Int64((abs(value) * 100).rounded())
        let whole = grouped(cents / 100)
        let sign = value < 0 && cents > 0 ? "-" : ""
        guard cents % 100 > 0 else {
            return sign + symbol + whole
        }
        return sign + symbol + whole + "." + String(format: "%02lld", cents % 100)
    }

    private static func grouped(_ value: Int64) -> String {
        let digits = String(value)
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return groups.joined(separator: ",")
    }
}
