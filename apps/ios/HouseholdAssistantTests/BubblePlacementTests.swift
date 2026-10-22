// How the thread groups bubbles into runs and where it puts the time.

import XCTest
@testable import HouseholdAssistant

final class BubblePlacementTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_789_787_000)

    private func message(_ voice: String, at minutes: Double) -> RoomMessage {
        RoomMessage(
            id: UUID().uuidString,
            author: voice,
            text: "x",
            media: [],
            replyTo: nil,
            sentAt: start.addingTimeInterval(minutes * 60),
            status: .sent
        )
    }

    func testConsecutiveMessagesFromOneVoiceFormARun() {
        let placements = BubblePlacement.placements(for: [
            message("owner", at: 0), message("owner", at: 1),
            message("assistant", at: 2), message("assistant", at: 3), message("assistant", at: 4),
        ])
        XCTAssertEqual(placements.map(\.startsRun), [true, false, true, false, false])
        XCTAssertEqual(placements.map(\.endsRun), [false, true, false, false, true])
    }

    func testTwoPeopleInAGroupAreTwoRunsEvenBackToBack() {
        let placements = BubblePlacement.placements(for: [
            message("sender:gia", at: 0), message("sender:ana", at: 1), message("sender:ana", at: 2),
        ])
        XCTAssertEqual(placements.map(\.startsRun), [true, true, false])
        XCTAssertEqual(placements.map(\.endsRun), [true, false, true])
    }

    /// The first time goes up top; after that, only a gap of an hour or more
    /// earns another, and that gap breaks the run even within one voice.
    func testATimeGoesAboveTheFirstMessageAndAfterAnHourOfQuiet() {
        let placements = BubblePlacement.placements(for: [
            message("owner", at: 0), message("owner", at: 59),
            message("owner", at: 59 + 60), message("assistant", at: 59 + 61),
        ])
        XCTAssertEqual(placements.map { $0.divider != nil }, [true, false, true, false])
        XCTAssertEqual(placements[2].divider, start.addingTimeInterval((59 + 60) * 60))
        XCTAssertEqual(placements.map(\.startsRun), [true, false, true, true])
        XCTAssertEqual(placements.map(\.endsRun), [false, true, true, true])
    }

    func testAnEmptyTranscriptHasNoPlacements() {
        XCTAssertTrue(BubblePlacement.placements(for: []).isEmpty)
    }

    /// The family room's history: every run opens once and closes once.
    func testTheFamilyRoomHistoryOpensAndClosesEveryRun() throws {
        guard case .response(let response) = try GatewayCodec.decode(try Fixtures.text("household-app-history-response")) else {
            throw GatewayConnectionError.unexpectedFrame
        }
        var thread = RoomThread(.family)
        thread.load(try XCTUnwrap(response.payload).decoded(as: RoomHistoryPage.self))
        let placements = BubblePlacement.placements(for: thread.messages)

        XCTAssertEqual(placements.count, thread.messages.count)
        XCTAssertTrue(try XCTUnwrap(placements.first).startsRun)
        XCTAssertTrue(try XCTUnwrap(placements.last).endsRun)
        XCTAssertEqual(placements.filter(\.startsRun).count, placements.filter(\.endsRun).count)
        XCTAssertNotNil(placements.first?.divider, "the history carries its times")
    }
}
