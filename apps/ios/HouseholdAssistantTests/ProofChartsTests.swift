// The two replies that proved, on 17 October 2026, that each assistant answers "put that in
// a chart" with a chart card: Corey from his own cost per day that week, Denise from a
// forecast she looked up. Each was asked on a throwaway session of its gateway with no chat
// behind it (CFO decision 1008250) and is kept here as it came back, the dashes and the
// degree sign written as escapes. This app's own parser must read each as one chart, which
// ChartsAndPicturesScreenshots then draws.

import XCTest
@testable import HouseholdAssistant

enum ProofReplies {
    static let corey = #"""
    Here's the week at a glance \#u{2014} Tuesday's answers cost the most, Thursday the least, and today's still adding up.

    ```steward-card
    {"type":"chart","title":"My daily answer cost, Oct 11\#u{2013}17","kind":"line","x":["Oct 11","Oct 12","Oct 13","Oct 14","Oct 15","Oct 16","Oct 17"],"series":[{"name":"Cost","values":[0.222,0.275,0.095,0.071,0.326,0.163,0.144]}],"unit":"$"}
    ```

    Total for the week so far: **$1.40**.
    """#

    static let denise = #"""
    Here are Chicago's forecast highs for the next five days, from Open-Meteo (today through Wednesday, Oct 21):

    ```steward-card
    {"type":"chart","title":"Chicago highs, next 5 days","kind":"bar","x":["Sat Oct 17","Sun Oct 18","Mon Oct 19","Tue Oct 20","Wed Oct 21"],"series":[{"name":"High","values":[53.8,59.2,66.5,63.3,67.4]}],"unit":"\#u{00B0}F"}
    ```

    A mild stretch ahead \#u{2014} it warms nicely from the low 50s today to the mid-60s by Monday, dips a touch Tuesday, then Wednesday is the warmest of the bunch at about 67\#u{00B0}F.
    """#
}

final class ProofChartsTests: XCTestCase {
    private struct NoChart: Error {}

    /// The one chart in a reply, or a failure when the parser made anything else of it.
    private func chart(in reply: String) throws -> ChartCard {
        let cards = StewardCardParser.segments(in: reply, isStreaming: false).compactMap { segment -> StewardCard? in
            if case .card(let card) = segment {
                return card
            }
            return nil
        }
        XCTAssertEqual(cards.count, 1)
        guard case .chart(let chart)? = cards.first?.content else {
            XCTFail("no chart card in the reply")
            throw NoChart()
        }
        return chart
    }

    func testCoreysProofReadsAsALineOfHisCostEachDay() throws {
        // Act
        let chart = try chart(in: ProofReplies.corey)

        // Assert
        XCTAssertEqual(chart.kind, .line)
        XCTAssertEqual(chart.labels, ["Oct 11", "Oct 12", "Oct 13", "Oct 14", "Oct 15", "Oct 16", "Oct 17"])
        XCTAssertEqual(chart.series.map(\.values), [[0.222, 0.275, 0.095, 0.071, 0.326, 0.163, 0.144]])
        XCTAssertEqual(chart.text(for: 0.326), "$0.33")
    }

    func testDenisesProofReadsAsBarsOfForecastHighsInFahrenheit() throws {
        // Act
        let chart = try chart(in: ProofReplies.denise)

        // Assert
        XCTAssertEqual(chart.kind, .bar)
        XCTAssertEqual(chart.labels.count, 5)
        XCTAssertEqual(chart.series.map(\.values), [[53.8, 59.2, 66.5, 63.3, 67.4]])
        XCTAssertEqual(chart.text(for: 67.4), "67.4\u{00B0}F")
    }
}
