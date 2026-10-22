#if canImport(UIKit)
import XCTest
@testable import HouseholdAssistant

@MainActor
final class ThreadSearchModelTests: XCTestCase {
    private func message(_ id: String, _ words: String) -> RoomMessage {
        RoomMessage(id: id, author: "corey", text: words, media: [], replyTo: nil, sentAt: Date(), status: .sent, rev: 1)
    }

    func testSubmitWhileTypingWaitsForTheNewQueryInsteadOfPickingAnOldResult() async {
        let search = ThreadSearchModel()
        let messages = [message("old", "recital"), message("new", "plumber")]
        search.open()
        search.query = "recital"
        await search.search(messages, heard: [:])
        search.query = "plumber"
        search.submit()
        XCTAssertNil(search.currentMatch)
        await search.search(messages, heard: [:])
        XCTAssertEqual(search.currentMatch?.messageId, "new")
        XCTAssertFalse(search.isListShown)
    }

    func testChangingFiltersInvalidatesSelectionAndNeverStepsIntoTheOldResults() async {
        let search = ThreadSearchModel()
        search.open()
        search.query = "recital"
        let messages = [message("words", "recital")]
        await search.search(messages, heard: [:])
        search.pick(0)
        search.filter = .files
        search.step(isOlder: true)
        XCTAssertNil(search.currentMatch)
        XCTAssertTrue(search.isListShown)
        await search.search(messages, heard: [:])
        XCTAssertTrue(search.matches.isEmpty)
        search.filter = .all
        await search.search(messages, heard: [:])
        XCTAssertEqual(search.matches.map(\.id), ["words"])
    }

    func testClosingSearchCancelsAnUnfinishedSubmissionAndReopeningStartsEmpty() async {
        let search = ThreadSearchModel()
        search.open()
        search.query = "plumber"
        search.submit()
        let request = Task { await search.search([message("one", "plumber")], heard: [:]) }
        await Task.yield()
        search.close()
        await request.value
        XCTAssertFalse(search.isOpen)
        XCTAssertTrue(search.matches.isEmpty)
        XCTAssertNil(search.currentMatch)
        search.open()
        XCTAssertFalse(search.hasQuery)
        XCTAssertEqual(search.filter, .all)
    }

    func testOlderSearchPagesHaveABudgetAndContinueFromTheirCursor() async throws {
        let search = ThreadSearchModel()
        search.open()
        search.query = "missing"
        let messages = [RoomMessage(id: "newest", author: "corey", text: "newest", media: [], replyTo: nil,
                                    sentAt: Date(), status: .sent, rev: 1_000)]
        var cursors: [Int] = []
        let load: (Int) async throws -> RoomHistoryPage = { before in
            cursors.append(before)
            let json = #"{"messages":[{"id":"m-\#(before - 1)","rev":\#(before - 1),"kind":"message","conversation":"direct","author":"corey","at":1,"origin":"local","text":"older","media":[]}],"hasMore":true,"reactions":{},"reads":[],"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{}}"#
            return try JSONDecoder().decode(RoomHistoryPage.self, from: Data(json.utf8))
        }
        await search.search(messages, heard: [:], hasOlder: true, loadPage: load)
        XCTAssertEqual(cursors, Array(stride(from: 1_000, through: 981, by: -1)))
        XCTAssertTrue(search.canSearchOlder)
        search.searchOlder()
        await search.search(messages, heard: [:], hasOlder: true, loadPage: load)
        XCTAssertEqual(cursors.count, 40)
        XCTAssertEqual(cursors[20], 980)
        XCTAssertTrue(search.matches.isEmpty)
        search.query = "newest"
        await search.search(messages, heard: [:])
        XCTAssertEqual(search.matches.first?.rev, 1_000)
        XCTAssertFalse(search.canSearchOlder)
    }
}
#endif
