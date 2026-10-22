// Searching a conversation finds words wherever they were said, newest first, one match a
// message, with about a line round what was found, and steps through the matches.

import XCTest
@testable import HouseholdAssistant

final class ThreadSearchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_018_800)

    private func message(_ id: String, _ text: String, minute: Int, media: [RoomMedia] = [], author: String = "corey") -> RoomMessage {
        RoomMessage(id: id, author: author, text: text, media: media, replyTo: nil, sentAt: start.addingTimeInterval(Double(minute) * 60), status: .sent, rev: minute)
    }

    private func media(_ id: String, _ kind: RoomMedia.Kind, name: String? = nil) -> RoomMedia {
        RoomMedia(id: id, kind: kind, mime: "application/octet-stream", bytes: 10, name: name)
    }

    func testFindsEveryMessageWithTheWordsNewestFirst() {
        // Arrange
        let messages = [
            message("a-1", "The dentist is Tuesday at 3:30.", minute: 1),
            message("d-2", "Thanks!", minute: 2, author: "franco"),
            message("a-3", "Done. The dentist is now Thursday.", minute: 3),
        ]

        // Act
        let found = ThreadSearch.matches(of: "dentist", in: messages)

        // Assert
        XCTAssertEqual(found.map(\.messageId), ["a-3", "a-1"])
        XCTAssertEqual(found.map(\.source), [.words, .words])
    }

    func testCaseAccentsAndMarkdownDoNotMatter() {
        // Arrange
        let messages = [
            message("a-1", "Here is the week:\n\n- **Monday** soccer at 5:45\n- *Café* with Gia", minute: 1),
        ]

        // Act
        let soccer = ThreadSearch.matches(of: "monday  SOCCER", in: messages)
        let cafe = ThreadSearch.matches(of: "cafe with", in: messages)

        // Assert
        XCTAssertEqual(soccer.first?.messageId, "a-1")
        XCTAssertEqual(cafe.first?.messageId, "a-1")
        let match = try? XCTUnwrap(soccer.first)
        XCTAssertEqual(match.map { String($0.snippet[$0.found]) }, "Monday soccer")
        XCTAssertFalse(match?.snippet.contains("*") ?? true, "the snippet shows words, not Markdown: \(match?.snippet ?? "")")
    }

    func testFindsWhatAVoiceNoteSaidAndWhatAFileIsCalled() {
        // Arrange
        let note = media("note", .voice)
        var heardByGateway = message("d-1", "", minute: 1, media: [media("other", .voice)], author: "franco")
        heardByGateway.heard = "Pick up milk on the way"
        let messages = [
            heardByGateway,
            message("d-2", "", minute: 2, media: [note], author: "franco"),
            message("d-3", "", minute: 3, media: [media("slip", .file, name: "Field trip permission slip.pdf")], author: "franco"),
            message("d-4", "Look at this", minute: 4, media: [media("photo", .photo, name: "IMG_0042.jpg")], author: "franco"),
        ]

        // Act
        let milk = ThreadSearch.matches(of: "milk", in: messages)
        let pasta = ThreadSearch.matches(of: "pasta", in: messages, heard: ["note": "Come home soon, the pasta is getting cold."])
        let slip = ThreadSearch.matches(of: "permission slip", in: messages)
        let photo = ThreadSearch.matches(of: "img_0042", in: messages)

        // Assert
        XCTAssertEqual(milk.map(\.messageId), ["d-1"])
        XCTAssertEqual(milk.first?.source, .voiceNote)
        XCTAssertEqual(pasta.map(\.messageId), ["d-2"])
        XCTAssertEqual(pasta.first?.source, .voiceNote)
        XCTAssertEqual(slip.map(\.messageId), ["d-3"])
        XCTAssertEqual(slip.first?.source, .file)
        XCTAssertEqual(photo.first?.source, .photo)
    }

    func testFindsTheLinesOfACardNotItsJSON() {
        // Arrange
        let chart = #"{"type":"chart","title":"Grocery spend by week","kind":"bar","x":["W1","W2"],"series":[{"name":"Spend","values":[142,118]}],"unit":"$"}"#
        let messages = [message("a-1", "Here it is.\n\n```steward-card\n\(chart)\n```", minute: 1)]

        // Act
        let byTitle = ThreadSearch.matches(of: "grocery spend", in: messages)
        let byJSON = ThreadSearch.matches(of: "series", in: messages)

        // Assert
        XCTAssertEqual(byTitle.map(\.messageId), ["a-1"])
        XCTAssertTrue(byJSON.isEmpty, "a card's JSON is not its words")
    }

    func testASnippetIsAboutALineRoundWhatWasFound() throws {
        // Arrange
        let long = String(repeating: "Before the words there is a long stretch of text. ", count: 4)
            + "The plumber comes Tuesday at 10."
            + String(repeating: " After the words there is another long stretch of text.", count: 4)
        let messages = [message("a-1", long, minute: 1)]

        // Act
        let match = try XCTUnwrap(ThreadSearch.matches(of: "plumber", in: messages).first)

        // Assert
        XCTAssertEqual(String(match.snippet[match.found]), "plumber")
        XCTAssertTrue(match.snippet.hasPrefix("…"), match.snippet)
        XCTAssertTrue(match.snippet.hasSuffix("…"), match.snippet)
        XCTAssertLessThanOrEqual(match.snippet.count, ThreadSearch.snippetBefore + "plumber".count + ThreadSearch.snippetAfter + 2)
        XCTAssertFalse(match.snippet.dropFirst().hasPrefix(" "), "it starts at a word: \(match.snippet)")
    }

    func testFindsTheWordsOfACall() throws {
        // Arrange
        let entry = try JSONValue.object([
            "id": .string("call:1"), "rev": .number(5),
            "kind": .string("call"), "conversation": .string("direct"), "author": .string("franco"),
            "at": .number(1_792_018_800_000), "endedAt": .number(1_792_018_900_000), "with": .string("corey"),
            "turnIds": .array([]),
            "transcript": .array([
                .object(["author": .string("franco"), "text": .string("What's on tomorrow morning?"), "at": .number(1_792_018_801_000)]),
                .object(["author": .string("corey"), "text": .string("School drop off at 7:45."), "at": .number(1_792_018_804_000)]),
            ]),
            "isCut": .bool(false), "origin": .string("local"),
        ]).decoded(as: RoomEntry.self)

        // Act
        let found = ThreadSearch.matches(of: "drop off", in: [RoomMessage(entry)])

        // Assert
        XCTAssertEqual(found.map(\.messageId), ["call:1"])
        XCTAssertEqual(found.first?.source, .call)
        XCTAssertEqual(ThreadSearch.matches(of: "drop off", in: [RoomMessage(entry)], filter: .calls).map(\.id), ["call:1"])
        XCTAssertTrue(ThreadSearch.matches(of: "drop off", in: [RoomMessage(entry)], filter: .files).isEmpty)
    }

    func testAnEmptySearchFindsNothing() {
        let messages = [message("a-1", "Anything at all", minute: 1)]

        for query in ["", "   ", "**"] {
            XCTAssertTrue(ThreadSearch.matches(of: query, in: messages).isEmpty, "\"\(query)\"")
        }
    }

    func testSharedFindsPicturesAndFilesByTheirWordsAndNamesInBothRooms() {
        // Arrange
        let beach = media("beach", .photo)
        let slip = media("slip", .file, name: "Field trip permission slip.pdf")
        let direct = [
            message("d-1", "Beach day at Seaside", minute: 1, media: [beach], author: "franco"),
            message("d-2", "Seaside was lovely", minute: 2, author: "franco"),
            message("d-3", "", minute: 3, media: [media("note", .voice)], author: "franco"),
        ]
        let family = [message("m-1", "Here it is", minute: 4, media: [slip], author: "gia")]

        // Act
        let seaside = SharedMedia.matching("seaside", in: [(.direct, direct), (.family, family)])
        let permission = SharedMedia.matching("permission", in: [(.direct, direct), (.family, family)])

        // Assert
        XCTAssertEqual(seaside.map(\.id), ["beach"], "words with no picture or file are not shared")
        XCTAssertEqual(seaside.first?.conversation, .direct)
        XCTAssertEqual(permission.map(\.id), ["slip"])
        XCTAssertEqual(permission.first?.conversation, .family)
    }

    func testFiltersFindCaptionsAndNamesWithoutLosingTheAttachmentMatch() {
        let messages = [
            message("words", "school pickup", minute: 1),
            message("voice", "school pickup", minute: 2, media: [media("v", .voice)]),
            message("photo", "school photo", minute: 3, media: [media("p", .photo)]),
            message("video", "school concert", minute: 4, media: [media("m", .video)]),
            message("file", "school form", minute: 5, media: [media("f", .file, name: "school.pdf")]),
        ]

        XCTAssertEqual(ThreadSearch.matches(of: "school", in: messages).map(\.id), ["file", "video", "photo", "voice", "words"])
        XCTAssertEqual(ThreadSearch.matches(of: "school", in: messages, filter: .voice).map(\.id), ["voice"])
        XCTAssertEqual(ThreadSearch.matches(of: "school", in: messages, filter: .photos).map(\.id), ["video", "photo"])
        let files = ThreadSearch.matches(of: "school", in: messages, filter: .files)
        XCTAssertEqual(files.map(\.id), ["file"], "matching both caption and name still gives one result")
        XCTAssertEqual(files.first?.source, .file)
        XCTAssertEqual(ThreadSearch.matches(of: "school", in: messages, filter: .messages).map(\.id), ["file", "video", "photo", "words"])
        XCTAssertTrue(ThreadSearch.matches(of: "school", in: messages, filter: .calls).isEmpty)
    }

    func testFilteringHappensBeforeTheResultLimit() {
        let file = message("file", "school form", minute: 0, media: [media("f", .file)])
        let words = (1...ThreadSearch.mostMatches).map { message("text-\($0)", "school", minute: $0) }
        let found = ThreadSearch.matches(of: "school", in: [file] + words, filter: .files)
        XCTAssertEqual(found.map(\.id), ["file"], "newer text matches must not hide an older file")
    }

    func testStepsOlderAndNewerAndStopsAtTheEnds() {
        // Arrange
        let messages = (1...3).map { message("a-\($0)", "soccer \($0)", minute: $0) }
        let found = ThreadSearch.matches(of: "soccer", in: messages)

        // Act and Assert
        XCTAssertEqual(ThreadSearch.step(from: nil, isOlder: true, in: found), 0, "older starts at the newest")
        XCTAssertNil(ThreadSearch.step(from: nil, isOlder: false, in: found))
        XCTAssertEqual(ThreadSearch.step(from: 0, isOlder: true, in: found), 1)
        XCTAssertEqual(ThreadSearch.step(from: 2, isOlder: true, in: found), 2, "the oldest stays")
        XCTAssertEqual(ThreadSearch.step(from: 1, isOlder: false, in: found), 0)
        XCTAssertEqual(ThreadSearch.step(from: 0, isOlder: false, in: found), 0, "the newest stays")
        XCTAssertNil(ThreadSearch.step(from: nil, isOlder: true, in: []))
    }
}

