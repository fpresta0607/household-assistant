// The Today card at the top of Chats (CFO notes section 21c), on the real app over the demo
// gateway: the next thing first with the line that helps with it, two more, the day's verse
// with its way to the Bible app, the whole day a tap opens, and the card shown from the
// phone's own copy with no link at all. It also times the card from the app's start to the
// card on screen, online and offline, five launches each, for the Scrawl page.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class TodayCardTests: XCTestCase {
    private static let timing = XCTOSSignpostMetric(subsystem: "com.siqstack.stewardai", category: "chat", name: "today")

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The demo on Chats, keeping what it shows on the phone, with nothing playing over it.
    private func app(isOffline: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-StewardDemo", "YES",
            "-StewardKeepThreads", "YES",
            "-StewardNetworkControl", "steward-today-" + UUID().uuidString,
        ] + (isOffline ? ["-StewardOffline", "YES"] : [])
        return app
    }

    func testTheCardShowsTheNextThingTwoMoreAndTheVerseAndATapOpensTheDay() {
        // Arrange
        let app = app(isOffline: false)
        app.launch()
        let card = app.buttons["today.card"]

        // Act
        XCTAssertTrue(card.waitForExistence(timeout: 15), "no Today card on Chats")

        // Assert
        XCTAssertTrue(card.label.contains("Next, Dentist"), card.label)
        XCTAssertTrue(card.label.contains("the roads are light"), card.label)
        XCTAssertTrue(card.label.contains("Then Lunch with Gia"), card.label)
        XCTAssertTrue(card.label.contains("Then Soccer pickup"), card.label)
        let verse = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Psalm 46:10")).firstMatch
        XCTAssertTrue(verse.exists, "the day's verse is not at the foot of the card")
        let open = app.buttons["today.verse.open"]
        XCTAssertTrue(open.exists && open.isHittable, "no way to the Bible app")
        XCTAssertEqual(open.label, "Open Psalm 46:10 in the Bible app")
        XCTAssertLessThan(card.frame.minY, app.buttons["pin.direct"].frame.minY, "the card is not above the pins")

        // Act
        card.tap()

        // Assert
        let day = app.descendants(matching: .any)["today.day"]
        XCTAssertTrue(day.waitForExistence(timeout: 5), "a tap did not open the whole day")
        let soccer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Soccer")).firstMatch
        XCTAssertTrue(soccer.exists, "the whole day leaves out what the card had no room for")
        app.buttons["Done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testTheCardIsTimedFromTheAppsStart() {
        // Arrange
        let app = app(isOffline: false)
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        // Act and assert
        measure(metrics: [Self.timing], options: options) {
            app.launch()
            XCTAssertTrue(app.buttons["today.card"].waitForExistence(timeout: 15), "no Today card on Chats")
        }
        app.terminate()
    }

    func testOfflineTheCardShowsFromThePhoneAndIsTimed() {
        // Arrange: online once, which keeps the card on the phone.
        let online = app(isOffline: false)
        online.launch()
        XCTAssertTrue(online.buttons["today.card"].waitForExistence(timeout: 15), "no Today card to keep")
        online.terminate()
        let offline = app(isOffline: true)
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        // Act and assert
        measure(metrics: [Self.timing], options: options) {
            offline.launch()
            XCTAssertTrue(offline.buttons["today.card"].waitForExistence(timeout: 10), "offline, the card did not show from the phone")
        }
        XCTAssertTrue(offline.buttons["today.verse.open"].exists, "offline, the verse did not come with the card")
        offline.terminate()
    }
}
