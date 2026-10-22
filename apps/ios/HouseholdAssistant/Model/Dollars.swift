// Dollars as Settings writes them: a price per million tokens as short as it can be
// ("$3", "$0.10", "$0.075"), and an amount spent always to the cent ("$38.40"), its sign
// before the dollar sign ("-$0.03").

import Foundation

enum Dollars {
    static func price(_ dollars: Double) -> String {
        if dollars == dollars.rounded() {
            return "$" + String(Int(dollars))
        }
        let cents = String(format: "%.2f", dollars)
        let finer = String(format: "%.3f", dollars)
        // Three places only when the third is not a zero.
        return "$" + (finer.hasSuffix("0") ? cents : finer)
    }

    static func amount(_ dollars: Double) -> String {
        (dollars < 0 ? "-$" : "$") + String(format: "%.2f", abs(dollars))
    }
}
