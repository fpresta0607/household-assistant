// Sharing from another app: the hand-off the Share Extension leaves in the App Group, how
// the app reads it back, what the message says, and the names files go by.

import Foundation
import XCTest
@testable import HouseholdAssistant

final class ShareTests: XCTestCase {
    private var folder: URL!
    private var outbox: ShareOutbox!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-tests-\(UUID().uuidString)", isDirectory: true)
        outbox = ShareOutbox(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let sharedAt = Date(timeIntervalSince1970: 1_792_018_800)

    /// A draft with one file in it, as the extension leaves it before Send.
    private func drafted(_ id: String, file: String = "IMG_0001.jpeg", bytes: Data = Data([1, 2, 3])) throws -> URL {
        let draft = try outbox.draft(id)
        try bytes.write(to: draft.appendingPathComponent(file))
        return draft
    }

    private func handoff(_ id: String, at: Date = sharedAt, items: [ShareHandoff.Item]) -> ShareHandoff {
        ShareHandoff(id: id, conversation: .family, text: "From the beach", items: items, at: at)
    }

    // MARK: - The hand-off

    func testAHandOffReadsBackAsTheExtensionPostedIt() throws {
        // Arrange
        let id = "6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"
        _ = try drafted(id, bytes: Data("photo".utf8))
        let posted = ShareHandoff(
            id: id,
            conversation: .direct,
            text: "Can we make this Sunday?",
            items: [ShareHandoff.Item(kind: .photo, file: "IMG_0001.jpeg")],
            at: Self.sharedAt
        )

        // Act
        try outbox.post(posted)
        let read = outbox.pending(now: Self.sharedAt)

        // Assert
        XCTAssertEqual(read, [posted])
        let file = try XCTUnwrap(read.first.map { outbox.file($0.items[0], of: $0) })
        XCTAssertEqual(try Data(contentsOf: file), Data("photo".utf8))
    }

    func testADraftIsNotReadUntilItIsPosted() throws {
        _ = try drafted("6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f")

        XCTAssertEqual(outbox.pending(now: Self.sharedAt), [])
    }

    func testHandOffsComeBackInTheOrderTheyWereShared() throws {
        let later = "bbbbbbbb-0000-4000-8000-000000000002"
        let earlier = "aaaaaaaa-0000-4000-8000-000000000001"
        for (id, minutes) in [(later, 5.0), (earlier, 1.0)] {
            _ = try drafted(id)
            try outbox.post(handoff(id, at: Self.sharedAt.addingTimeInterval(minutes * 60), items: [ShareHandoff.Item(kind: .photo, file: "IMG_0001.jpeg")]))
        }

        XCTAssertEqual(outbox.pending(now: Self.sharedAt).map(\.id), [earlier, later])
    }

    func testASentHandOffIsGoneWithItsFiles() throws {
        let id = "6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"
        _ = try drafted(id)
        let posted = handoff(id, items: [ShareHandoff.Item(kind: .photo, file: "IMG_0001.jpeg")])
        try outbox.post(posted)
        let file = outbox.file(posted.items[0], of: posted)

        outbox.remove(id)

        XCTAssertEqual(outbox.pending(now: Self.sharedAt), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testACancelledShareLeavesNothingBehind() throws {
        let id = "6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"
        let draft = try drafted(id)

        outbox.discard(id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.path))
    }

    /// The extension was closed half way through: after an hour nothing will finish it.
    func testADraftAbandonedForAnHourIsCleared() throws {
        let abandoned = try drafted("aaaaaaaa-0000-4000-8000-000000000001")
        let fresh = try drafted("bbbbbbbb-0000-4000-8000-000000000002")
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 3600)], ofItemAtPath: abandoned.path)

        _ = outbox.pending(now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "still being written")
    }

    func testPostingAHandOffThatNamesAMissingFileFails() throws {
        let id = "6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"
        _ = try drafted(id)

        XCTAssertThrowsError(try outbox.post(handoff(id, items: [ShareHandoff.Item(kind: .video, file: "Clip.mov")])))
        XCTAssertEqual(outbox.pending(now: Self.sharedAt), [])
    }

    func testPostingWithoutADraftFails() {
        XCTAssertThrowsError(try outbox.post(handoff("6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f", items: [])))
    }

    /// The App Group is shared by two processes, so what is in it is checked before it is
    /// sent: one that does not hold together is thrown away rather than tried at every start.
    func testAHandOffThatDoesNotHoldTogetherIsThrownAway() throws {
        let id = "6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"
        let other = "aaaaaaaa-0000-4000-8000-000000000001"
        let cases: [(name: String, folder: String, manifest: Data)] = [
            ("not JSON", id, Data("{".utf8)),
            ("another hand-off's id", id, try JSONEncoder().encode(handoff(other, items: []))),
            ("a file outside its folder", id, try JSONEncoder().encode(handoff(id, items: [ShareHandoff.Item(kind: .file, file: "../keys")]))),
            ("a file that is not there", id, try JSONEncoder().encode(handoff(id, items: [ShareHandoff.Item(kind: .file, file: "Gone.pdf")]))),
            ("the hand-off itself as a file", id, try JSONEncoder().encode(handoff(id, items: [ShareHandoff.Item(kind: .file, file: ShareOutbox.manifest)]))),
            ("a folder that is no id", "..x", try JSONEncoder().encode(handoff("..x", items: []))),
        ]
        for (name, folderName, manifest) in cases {
            // Arrange
            let ready = folder.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
            try manifest.write(to: ready.appendingPathComponent(ShareOutbox.manifest))

            // Act
            let read = outbox.pending(now: Self.sharedAt)

            // Assert
            XCTAssertEqual(read, [], name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ready.path), name)
        }
    }

    func testForgettingThePairingEmptiesTheOutbox() throws {
        let id = "6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"
        _ = try drafted(id)
        try outbox.post(handoff(id, items: [ShareHandoff.Item(kind: .photo, file: "IMG_0001.jpeg")]))
        _ = try drafted("aaaaaaaa-0000-4000-8000-000000000001")

        outbox.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(outbox.pending(now: Self.sharedAt), [])
    }

    func testAnOutboxNobodyHasWrittenToHasNothingWaiting() {
        XCTAssertEqual(outbox.pending(now: Self.sharedAt), [])
    }

    func testOnlyAnIdThatCanNameAMessageStartsADraft() {
        for id in ["", "..", "a/b", "short", "6f1c2a9e_0d4b", String(repeating: "a", count: 79)] {
            XCTAssertThrowsError(try outbox.draft(id), id)
        }
        XCTAssertNoThrow(try outbox.draft("6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"))
    }

    // MARK: - What the message says

    func testTheWordsComeFirstThenWhatWasSharedThenEachLinkNotAlreadySaid() throws {
        let recipe = try XCTUnwrap(URL(string: "https://example.com/weeknight-pesto-pasta"))
        let map = try XCTUnwrap(URL(string: "https://maps.apple.com/?q=Pool"))
        let cases: [(words: String, shared: [String], links: [URL], text: String)] = [
            ("Can we make this Sunday?", [], [recipe], "Can we make this Sunday?\n\(recipe.absoluteString)"),
            ("  Look  \n", ["Weeknight pesto pasta"], [recipe], "Look\nWeeknight pesto pasta\n\(recipe.absoluteString)"),
            ("", ["Pesto \(recipe.absoluteString)"], [recipe], "Pesto \(recipe.absoluteString)"),
            ("Here: \(recipe.absoluteString)", [], [recipe, map, recipe], "Here: \(recipe.absoluteString)\n\(map.absoluteString)"),
            ("", ["", "  "], [], ""),
            ("Just words", [], [], "Just words"),
            // An app may hand over the same words as the item's text and as an attachment.
            ("", ["Pick up basil", " Pick up basil\n"], [], "Pick up basil"),
        ]
        for (words, shared, links, text) in cases {
            XCTAssertEqual(ShareHandoff.text(words: words, shared: shared, links: links), text, words)
        }
    }

    func testAHandOffSaysWhatItCarries() {
        func items(_ kinds: [ShareHandoff.Item.Kind]) -> [ShareHandoff.Item] {
            kinds.enumerated().map { ShareHandoff.Item(kind: $1, file: "file-\($0)") }
        }
        let cases: [(kinds: [ShareHandoff.Item.Kind], summary: String)] = [
            ([], "your message"),
            ([.photo], "a photo"),
            ([.photo, .photo], "2 photos"),
            ([.video], "a video"),
            ([.file, .file, .file], "3 files"),
            ([.photo, .file], "a photo and a file"),
            ([.file, .video, .photo, .photo], "2 photos, a video and a file"),
        ]
        for (kinds, summary) in cases {
            XCTAssertEqual(handoff("6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f", items: items(kinds)).summary, summary, summary)
        }
    }

    // MARK: - File names

    func testAFileKeepsAPlainNameOfItsOwn() {
        let cases: [(name: String, taken: Set<String>, plain: String)] = [
            ("IMG_0001.jpeg", [], "IMG_0001.jpeg"),
            ("IMG_0001.jpeg", ["img_0001.JPEG"], "IMG_0001 2.jpeg"),
            ("IMG_0001.jpeg", ["IMG_0001.jpeg", "IMG_0001 2.jpeg"], "IMG_0001 3.jpeg"),
            ("Notes", ["Notes"], "Notes 2"),
            ("Trip/Plan: v2.pdf", [], "Trip-Plan- v2.pdf"),
            ("  ", [], "File"),
            ("..", [], "File"),
            (".hidden.txt", [], "hidden.txt"),
            (ShareOutbox.manifest, [ShareOutbox.manifest], "handoff 2.json"),
            (String(repeating: "\u{1F338}", count: 80) + ".png", [], String(repeating: "\u{1F338}", count: 49) + ".png"),
        ]
        for (name, taken, plain) in cases {
            XCTAssertEqual(PlainFileName.unique(name, taken: taken), plain, name)
        }
    }

    func testOnlyAPlainNameIsAFileOfItsOwn() {
        for name in ["IMG_0001.jpeg", "Field trip permission slip.pdf", "Notes 2"] {
            XCTAssertTrue(PlainFileName.isPlain(name), name)
        }
        for name in ["", ".", "..", "../keys", "a/b", ".hidden", "a\u{0}b"] {
            XCTAssertFalse(PlainFileName.isPlain(name), name)
        }
    }

    /// A photo shared out of a conversation goes by what it is, not by the hash the
    /// gateway keeps it under.
    func testAnAttachmentGoesByWhatItIsAsAFile() {
        let hash = String(repeating: "a", count: 64)
        let cases: [(media: RoomMedia, name: String)] = [
            (RoomMedia(id: hash, kind: .photo, mime: "image/jpeg", bytes: 1), "Photo.jpg"),
            (RoomMedia(id: hash, kind: .video, mime: "video/quicktime", bytes: 1), "Video.mov"),
            (RoomMedia(id: hash, kind: .voice, mime: "audio/mp4", bytes: 1), "Voice note.m4a"),
            (RoomMedia(id: hash, kind: .file, mime: "application/pdf", bytes: 1, name: "Field trip permission slip.pdf"), "Field trip permission slip.pdf"),
            (RoomMedia(id: hash, kind: .file, mime: "application/pdf", bytes: 1), "File.pdf"),
        ]
        for (media, name) in cases {
            XCTAssertEqual(media.fileName, name, name)
        }
    }
}
