import XCTest
@testable import HouseholdAssistant

final class ChatHistoryLimitsTests: XCTestCase {
    private func message(_ rev: Int, text: String = "A saved message") -> RoomMessage {
        RoomMessage(id: "m-\(rev)", author: "franco", text: text, media: [], replyTo: nil,
                    sentAt: Date(timeIntervalSince1970: Double(rev)), status: .sent, rev: rev)
    }

    func testLiveWindowKeepsNewestAndNeverEvictsAnUnsentMessage() {
        var thread = RoomThread(.family)
        for rev in 1...1_050 { thread.addPending(message(rev)) }
        thread.addPending(RoomMessage(id: "waiting", author: "franco", text: "Not sent yet", media: [],
                                      replyTo: nil, sentAt: Date(), status: .waiting))
        XCTAssertTrue(thread.boundHistory())
        XCTAssertEqual(thread.messages.filter { $0.rev != nil }.count, 1_000)
        XCTAssertEqual(thread.oldestRev, 51)
        XCTAssertEqual(thread.latestRev, 1_050)
        XCTAssertEqual(thread.messages.last?.id, "waiting")
        XCTAssertTrue(thread.hasOlder)
    }

    func testReadingOlderKeepsTheOlderEndWithoutChangingTheLiveWindow() {
        var live = RoomThread(.family)
        for rev in 1...1_050 { live.addPending(message(rev)) }
        var reading = live
        reading.boundHistory(keepingNewest: false)
        live.boundHistory()
        XCTAssertEqual(reading.oldestRev, 1)
        XCTAssertEqual(reading.latestRev, 1_000)
        XCTAssertEqual(live.oldestRev, 51)
        XCTAssertEqual(live.latestRev, 1_050)
    }

    func testByteLimitPreservesWholeUnicodeMessages() {
        var thread = RoomThread(.direct)
        let words = String(repeating: "🏡", count: 65_536)
        for rev in 1...20 { thread.addPending(message(rev, text: words)) }
        XCTAssertTrue(thread.boundHistory())
        XCTAssertEqual(thread.messages.count, 16)
        XCTAssertTrue(thread.messages.allSatisfy { $0.text == words })
        XCTAssertLessThanOrEqual(thread.messages.reduce(0) { $0 + $1.text.utf8.count }, RoomThread.mostLoadedTextBytes)
    }

    func testArchiveIsBoundedByBytesAndLeavesTheSourceAndWaitingSendsIntact() throws {
        let archive = RoomArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { archive.forget() }
        let text = String(repeating: "x", count: 200_000)
        let changes = (1...60).map { JSONValue.object(["id": .string("m-\($0)"), "text": .string(text)]) }
        let kept = RoomArchive.Kept(page: .object(["messages": .array([])]), changes: changes)
        let waiting = RoomArchive.Waiting(id: "pending", conversation: .family, author: "franco", text: text,
                                          replyTo: nil, at: 1, attachments: [])
        archive.writeWaiting([waiting])
        archive.write(kept, for: .family)
        let file = archive.directory.appendingPathComponent("family.json")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, RoomArchive.mostHistoryBytes)
        let restored = try XCTUnwrap(archive.read(.family))
        XCTAssertLessThan(restored.changes.count, changes.count)
        XCTAssertEqual(restored.changes.last?["id"]?.stringValue, "m-60")
        XCTAssertEqual(kept.changes.count, 60)
        XCTAssertEqual(archive.readWaiting(), [waiting])
    }

    func testOversizedLegacyCacheIsNotLoadedIntoMemory() throws {
        let archive = RoomArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { archive.forget() }
        try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
        try Data(repeating: 32, count: RoomArchive.mostHistoryBytes + 1)
            .write(to: archive.directory.appendingPathComponent("direct.json"))
        XCTAssertNil(archive.read(.direct))
    }
}
