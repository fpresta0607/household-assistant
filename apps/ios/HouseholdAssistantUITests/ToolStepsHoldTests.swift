// While Corey works, the line in his typing bubble that says what he is doing stays long
// enough to read, even for tools done in a blink: each step holds about half a second, and
// steps that come while one holds wait their turn rather than flash past. The demo has
// Corey use three tools 60 ms apart on the test's cue and then answer (DemoGateway). How
// long each step held is what the app logged as each gave way (ThreadLog).

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class ToolStepsHoldTests: XCTestCase {
    /// The demo's steps, in order, as the app names them.
    private static let steps = ["calendar", "memory", "webSearch"]
    /// The least a step may hold and still be read.
    private static let readable = 400

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEachQuickStepHoldsLongEnoughToRead() throws {
        // Arrange
        let app = XCUIApplication()
        let control = "steward-steps-" + UUID().uuidString
        app.launchArguments = ["-StewardDemo", "YES", "-StewardNewRowsControl", control, "-StewardThreadLog", "YES"]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30), "Chats never showed")
        pin.tap()
        let list = app.collectionViews["room.thread"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the thread never showed")
        // The thread settles at its newest before Corey starts.
        Thread.sleep(forTimeInterval: 1)
        let working = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Corey is")).firstMatch
        let reply = list.descendants(matching: .any).matching(identifier: "room.message")
            .matching(NSPredicate(format: "label CONTAINS %@", "That is all the steps found.")).firstMatch
        let threadLog = app.descendants(matching: .any)["debug.threadLog"]
        let done = XCTDarwinNotificationExpectation(notificationName: control + ".steps.done")

        // Act
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName((control + ".steps") as CFString), nil, nil, true
        )
        var said: [String] = []
        var held: [(step: String, milliseconds: Int)] = []
        let end = Date().addingTimeInterval(12)
        while Date() < end, !reply.exists {
            if let label = (try? working.snapshot())?.label, said.last != label {
                said.append(label)
            }
            for line in threadLog.label.components(separatedBy: " | ") {
                if let step = Self.hold(in: line), !held.contains(where: { $0.step == step.step && $0.milliseconds == step.milliseconds }) {
                    held.append(step)
                }
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed, "the demo never finished")

        // Assert
        XCTAssertTrue(reply.exists, "Corey's answer never came after the steps. Said: \(said)")
        XCTAssertEqual(held.map { $0.step }, Self.steps, "the steps did not each show in turn. Held: \(held). Said: \(said)")
        for (step, milliseconds) in held {
            XCTAssertGreaterThanOrEqual(milliseconds, Self.readable, "\(step) flashed past in \(milliseconds) ms. Said: \(said)")
        }
    }

    /// A line the typing bubble logs as a step gives way: "step calendar held 503 ms".
    private static func hold(in line: String) -> (step: String, milliseconds: Int)? {
        let words = line.split(separator: " ")
        guard words.count == 5, words[0] == "step", words[2] == "held", words[4] == "ms", let milliseconds = Int(words[3]) else {
            return nil
        }
        return (String(words[1]), milliseconds)
    }
}
