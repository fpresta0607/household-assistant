import XCTest

@MainActor
final class SpendSelectionTests: XCTestCase {
    nonisolated override func setUpWithError() throws { continueAfterFailure = false }

    func testSelectingADayUpdatesTheHeadlineAndKeepsItAfterLiftingAndRetapping() {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardNewRowsControl", "spend-" + UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30))
        app.navigationBars.buttons["Settings"].tap()
        let spend = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Spend")).firstMatch
        for _ in 0..<6 {
            if spend.exists && spend.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(spend.isHittable)
        spend.tap()

        let summary = app.descendants(matching: .any).matching(identifier: "spend.summary").firstMatch
        let chart = app.descendants(matching: .any).matching(identifier: "spend.chart").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("$38.40"))
        XCTAssertTrue(chart.exists)

        // A point in the recorded half of the month, away from both plot edges.
        let point = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6))
        point.tap()
        let selected = NSPredicate(format: "label CONTAINS %@", "By October")
        expectation(for: selected, evaluatedWith: summary)
        waitForExpectations(timeout: 5)
        let selectedLabel = summary.label
        XCTAssertTrue(selectedLabel.contains("$"))
        XCTAssertFalse(selectedLabel.contains("$38.40"))
        point.tap()
        XCTAssertEqual(summary.label, selectedLabel, "lifting and re-tapping must keep the day's spend")

        // The last recorded day is selectable too, even though its amount equals the
        // month's total. Scrubbing to it must retain both its date and its amount.
        let lastDay = chart.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "October 15")).firstMatch
        XCTAssertTrue(lastDay.exists)
        point.press(forDuration: 0.1, thenDragTo: lastDay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(summary.label.contains("By October 15"))
        XCTAssertTrue(summary.label.contains("$38.40"))
        lastDay.tap()
        XCTAssertTrue(summary.label.contains("By October 15"))
        XCTAssertTrue(summary.label.contains("$38.40"))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "spend-selected-day"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["spend.show-month"].tap()
        XCTAssertTrue(summary.label.contains("$38.40"))
        XCTAssertTrue(summary.label.contains("October so far"))
    }
}
