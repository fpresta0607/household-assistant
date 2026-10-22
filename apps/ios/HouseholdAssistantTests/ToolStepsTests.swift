// What the working line says while the assistant uses its tools: each step at once when
// nothing holds the line, held long enough to read however quick its tool, the steps that
// come meanwhile in turn, and the dots once nothing waits.

import XCTest
@testable import HouseholdAssistant

final class ToolStepsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_018_800)

    private func at(_ milliseconds: Int) -> Date {
        start.addingTimeInterval(Double(milliseconds) / 1000)
    }

    func testAStepShowsAtOnceOverTheDots() {
        var steps = ToolSteps()

        steps.follow(.calendar, at: at(0))

        XCTAssertEqual(steps.shown, .calendar)
        XCTAssertNil(steps.nextChange, "nothing waits while the step's tool still runs")
    }

    func testAQuickStepHoldsUntilItCanBeRead() {
        // Arrange
        var steps = ToolSteps()
        steps.follow(.calendar, at: at(0))

        // Act
        steps.follow(nil, at: at(60))
        steps.advance(at: at(300))

        // Assert
        XCTAssertEqual(steps.shown, .calendar, "still held at 300 ms")
        XCTAssertEqual(steps.nextChange, at(500))
        steps.advance(at: at(500))
        XCTAssertNil(steps.shown, "the dots once it has been held")
        XCTAssertNil(steps.nextChange)
    }

    func testStepsThatComeWhileOneHoldsWaitTheirTurnInOrder() {
        // Arrange
        var steps = ToolSteps()
        steps.follow(.calendar, at: at(0))

        // Act
        for (milliseconds, activity) in [(60, nil), (120, .memory), (180, nil), (240, .webSearch), (300, nil)] as [(Int, AssistantActivity?)] {
            steps.follow(activity, at: at(milliseconds))
        }
        var shown: [AssistantActivity?] = [steps.shown]
        while let next = steps.nextChange {
            steps.advance(at: next)
            shown.append(steps.shown)
        }

        // Assert
        XCTAssertEqual(shown, [.calendar, .memory, .webSearch, nil])
        XCTAssertEqual(steps.shownAt, nil)
    }

    func testEachWaitingStepIsHeldInFull() {
        var steps = ToolSteps()
        steps.follow(.calendar, at: at(0))
        steps.follow(.memory, at: at(50))

        steps.advance(at: at(500))

        XCTAssertEqual(steps.shown, .memory)
        XCTAssertEqual(steps.shownAt, at(500))
        XCTAssertEqual(steps.nextChange, nil, "memory is still running")
        steps.follow(nil, at: at(700))
        XCTAssertEqual(steps.shown, .memory, "held from 500 ms, not from when it began")
        XCTAssertEqual(steps.nextChange, at(1000))
    }

    func testAStepHeldLongEnoughGivesWayAtOnce() {
        var steps = ToolSteps()
        steps.follow(.calendar, at: at(0))

        steps.follow(nil, at: at(2000))
        XCTAssertNil(steps.shown, "the dots as soon as the slow tool is done")

        steps.follow(.mail, at: at(2100))
        XCTAssertEqual(steps.shown, .mail, "and the next step at once")
    }

    func testTheSameStepAgainDoesNotWaitItsTurn() {
        var steps = ToolSteps()
        steps.follow(.calendar, at: at(0))
        steps.follow(nil, at: at(60))
        steps.follow(.calendar, at: at(120))
        steps.follow(nil, at: at(180))

        steps.advance(at: at(500))

        XCTAssertNil(steps.shown, "one calendar step held once, then the dots")
    }
}
