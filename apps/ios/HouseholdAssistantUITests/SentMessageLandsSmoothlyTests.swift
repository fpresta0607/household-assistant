// What Leo sends lands in Corey's thread in one smooth movement: it rises out of its own
// corner just above the composer and stays there, through the gateway keeping it a moment
// later and "Delivered" showing under it. Nothing about it moves or changes size once it
// has landed. The demo keeps what he sends two seconds later, as a gateway over a slow
// network does (DemoGateway), so the test sees the message both before and after it is kept.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class SentMessageLandsSmoothlyTests: XCTestCase {
    /// Where the sent message stood each time the test looked.
    private struct Sample {
        /// Seconds since Send was tapped.
        let at: TimeInterval
        /// The room between the message's bottom edge and the top of the message field.
        let gap: CGFloat
        let height: CGFloat
        let isDelivered: Bool
    }

    /// How far the message's bottom edge may move while it rises: it grows out of its row's
    /// bottom corner, and the row keeps the room for "Delivered" under it.
    private static let riseShift: CGFloat = 3
    /// By when the rise has settled.
    private static let risen: TimeInterval = 0.5

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testASentMessageLandsWithoutAJump() throws {
        // Arrange
        let app = XCUIApplication()
        app.launchArguments = [
            "-StewardDemo", "YES", "-StewardNewRowsControl", "steward-sent-" + UUID().uuidString, "-StewardThreadLog", "YES",
        ]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30), "Chats never showed")
        pin.tap()
        let list = app.collectionViews["room.thread"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the thread never showed")
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the message field is missing")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never rose")
        let words = "On my way, see you at six"
        field.typeText(words)
        // The thread settles with the keyboard up before anything is sent.
        Thread.sleep(forTimeInterval: 1)
        let sent = list.descendants(matching: .any).matching(identifier: "room.message")
            .matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
        let delivered = app.staticTexts["Delivered"]

        // Act
        app.buttons["Send"].tap()
        let tapped = Date()
        var samples: [Sample] = []
        while Date().timeIntervalSince(tapped) < 4 {
            if let frame = try? sent.snapshot().frame, let fieldFrame = try? field.snapshot().frame {
                samples.append(Sample(
                    at: Date().timeIntervalSince(tapped),
                    gap: fieldFrame.minY - frame.maxY,
                    height: frame.height,
                    isDelivered: delivered.exists
                ))
            }
        }
        let log = app.descendants(matching: .any)["debug.threadLog"].label

        // Assert
        let first = try XCTUnwrap(samples.first, "the sent message never showed. \(log)")
        XCTAssertFalse(first.isDelivered, "the test first saw the message only once it was kept: \(samples.count) looks. \(log)")
        XCTAssertTrue(samples.last?.isDelivered == true, "\"Delivered\" never showed under the sent message. \(log)")
        let gaps = samples.map(\.gap)
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, -1, "the composer covered the sent message: \(gaps). \(log)")
        XCTAssertLessThan(first.gap, 80, "the sent message landed far above the composer: \(gaps). \(log)")
        XCTAssertLessThanOrEqual(
            (gaps.max() ?? 0) - (gaps.min() ?? 0), Self.riseShift, "the sent message moved after it landed: \(gaps). \(log)"
        )
        let heights = samples.filter { $0.at > Self.risen }.map(\.height)
        XCTAssertLessThanOrEqual(
            (heights.max() ?? 0) - (heights.min() ?? 0), 0.5, "the sent message changed size after it rose: \(heights). \(log)"
        )
        XCTAssertGreaterThanOrEqual(delivered.frame.minY, sent.frame.maxY - 1, "\"Delivered\" is not under the sent message")
    }
}
