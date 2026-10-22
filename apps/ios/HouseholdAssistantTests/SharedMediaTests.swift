// The strip under the pins on Chats: what was shared in both conversations.

import XCTest
@testable import HouseholdAssistant

final class SharedMediaTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_018_800)

    private func media(_ id: String, _ kind: RoomMedia.Kind = .photo) -> RoomMedia {
        RoomMedia(id: id, kind: kind, mime: "image/png", bytes: 1)
    }

    private func message(_ id: String, minutes: Double, media: [RoomMedia], rev: Int? = 1) -> RoomMessage {
        RoomMessage(
            id: id,
            author: "gia",
            text: "",
            media: media,
            replyTo: nil,
            sentAt: start.addingTimeInterval(minutes * 60),
            status: rev == nil ? .sending : .sent,
            rev: rev
        )
    }

    func testBothConversationsShareOneStripNewestFirst() {
        let shared = SharedMedia.latest(
            in: [
                (.family, [message("m-1", minutes: 1, media: [media("photo")]), message("m-3", minutes: 3, media: [media("clip", .video)])]),
                (.direct, [message("d-2", minutes: 2, media: [media("slip", .file)])]),
            ],
            limit: 8
        )
        XCTAssertEqual(shared.map(\.id), ["clip", "slip", "photo"])
        XCTAssertEqual(shared.map(\.conversation), [.family, .direct, .family])
        XCTAssertEqual(shared.first?.author, "gia")
    }

    /// A voice note is said, not shared: it stays in its thread.
    func testAVoiceNoteIsNeverInTheStrip() {
        // Act
        let shared = SharedMedia.latest(
            in: [(.direct, [message("d-1", minutes: 1, media: [media("photo")]), message("d-2", minutes: 2, media: [media("note", .voice)])])],
            limit: 8
        )

        // Assert
        XCTAssertEqual(shared.map(\.id), ["photo"])
    }

    /// An attachment still uploading has no name the gateway knows yet, so it waits.
    func testOnlyWhatTheGatewayKeptIsShared() {
        let shared = SharedMedia.latest(
            in: [(.family, [message("m-1", minutes: 1, media: [media("kept")]), message("m-2", minutes: 2, media: [media("pending:1")], rev: nil)])],
            limit: 8
        )
        XCTAssertEqual(shared.map(\.id), ["kept"])
    }

    /// The same photo sent twice shows once, where it was sent last.
    func testTheSameAttachmentShowsOnceAndTheStripIsCapped() {
        let shared = SharedMedia.latest(
            in: [
                (.family, [message("m-1", minutes: 1, media: [media("photo")]), message("m-2", minutes: 2, media: [media("a"), media("b")])]),
                (.direct, [message("d-3", minutes: 3, media: [media("photo")])]),
            ],
            limit: 2
        )
        XCTAssertEqual(shared.map(\.id), ["photo", "a"])
        XCTAssertEqual(shared.first?.conversation, .direct)
    }

    func testNothingSharedIsAnEmptyStrip() {
        XCTAssertEqual(SharedMedia.latest(in: [(.family, []), (.direct, [])], limit: 8), [])
    }
}
