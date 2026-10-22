// The family room's shared look as the phone reads it (notes section 8): the look a page
// carries, read whatever a later gateway adds; the line each change shows as, with who made
// it; and those lines among the room's messages, each once, at its time.

import XCTest
@testable import HouseholdAssistant

final class FamilyLookTests: XCTestCase {
    private static let white = RingColor(red: 1, green: 1, blue: 1)
    private static let at = 1_792_018_800_000

    private func look(_ members: [String: JSONValue]) throws -> FamilyLook {
        try JSONValue.object(members).decoded(as: FamilyLook.self)
    }

    private func entry(
        _ id: String,
        rev: Int,
        kind: String = "look",
        author: String = "gia",
        at: Int = 1_792_018_800_000,
        extra: [String: JSONValue]
    ) throws -> RoomEntry {
        var members: [String: JSONValue] = [
            "id": .string(id), "rev": .number(Double(rev)), "kind": .string(kind),
            "conversation": .string("family"), "author": .string(author),
            "at": .number(Double(at)), "origin": .string("peer"),
        ]
        members.merge(extra) { _, own in own }
        return try JSONValue.object(members).decoded(as: RoomEntry.self)
    }

    private func message(_ id: String, rev: Int, at: Int) throws -> RoomEntry {
        try entry(id, rev: rev, kind: "message", author: "franco", at: at, extra: ["text": .string("hello"), "media": .array([])])
    }

    private static let whiteJSON: JSONValue = .object(["red": .number(1), "green": .number(1), "blue": .number(1)])

    /// The captured history page with `extra` in it.
    private func historyPage(_ extra: [String: JSONValue]) throws -> RoomHistoryPage {
        guard case .response(let response) = try GatewayCodec.decode(try Fixtures.text("household-app-history-response")),
              case .object(var members)? = response.payload else {
            throw XCTSkip("the captured history page is not an object")
        }
        members.merge(extra) { _, own in own }
        return try JSONValue.object(members).decoded(as: RoomHistoryPage.self)
    }

    // MARK: - The look

    func testALookReadsAsTheGatewayFoldedIt() throws {
        // Arrange, Act
        let read = try look(["ring": Self.whiteJSON, "appearance": .string("custom"), "background": .string("night")])

        // Assert
        XCTAssertEqual(read, FamilyLook(ring: Self.white, appearance: .custom, background: .night))
        XCTAssertEqual(read.sharedBackground, .night)
    }

    func testAPartThisVersionCannotReadIsLeftAsItStands() throws {
        // Arrange
        let cases: [(members: [String: JSONValue], expected: FamilyLook)] = [
            ([:], .standard),
            (["appearance": .string("loud")], .standard),
            (["ring": .string("red"), "appearance": .string("custom")], FamilyLook(ring: nil, appearance: .custom, background: nil)),
            // A phone's own photo is never everyone's background.
            (["appearance": .string("custom"), "background": .string("photo")], FamilyLook(ring: nil, appearance: .custom, background: nil)),
            (["ring": .null, "appearance": .string("auto"), "background": .string("dawn")], FamilyLook(ring: nil, appearance: .auto, background: .dawn)),
        ]

        for (members, expected) in cases {
            // Act, Assert
            XCTAssertEqual(try look(members), expected, "\(members)")
        }
    }

    func testAutoDrawsEachPhonesOwnBackgroundAndCustomItsOwnOrTheRainbow() {
        XCTAssertNil(FamilyLook(ring: nil, appearance: .auto, background: .night).sharedBackground)
        XCTAssertEqual(FamilyLook(ring: nil, appearance: .custom, background: nil).sharedBackground, .rainbow)
        XCTAssertEqual(FamilyLook(ring: nil, appearance: .custom, background: .dawn).sharedBackground, .dawn)
    }

    // MARK: - Lines

    func testEachChangeSaysWhatItChangedAndWho() {
        // Arrange
        let said: [(change: FamilyLookChange, words: String)] = [
            (.photo, "Gia changed the group photo"),
            (.color(Self.white), "Gia changed the group color"),
            (.color(nil), "Gia set the group color back to white"),
            (.appearance(.auto, background: nil), "Gia set the group's appearance to Auto"),
            (.appearance(.custom, background: nil), "Gia set the group's appearance to Custom"),
            (.appearance(.custom, background: .night), "Gia changed the group's background to Night"),
        ]

        for (change, words) in said {
            // Act
            let line = FamilyLookLine(id: "look", author: "gia", sentAt: Date(), rev: 1, change: change)

            // Assert
            XCTAssertEqual(line.words(by: "Gia"), words)
        }
    }

    func testALookEntryIsALineAndAChangeALaterGatewayAddsIsNone() throws {
        // Arrange
        let color = try entry("look:gia:1", rev: 4, extra: ["change": .string("color"), "ring": Self.whiteJSON])
        let custom = try entry("look:gia:2", rev: 5, extra: ["change": .string("appearance"), "appearance": .string("custom"), "background": .string("dawn")])
        let renamed = try entry("look:gia:3", rev: 6, extra: ["change": .string("name"), "name": .string("The Gang")])
        let said = try message("m-1", rev: 7, at: Self.at)

        // Act, Assert
        XCTAssertEqual(color.kind, .look)
        XCTAssertEqual(color.lookLine?.change, .color(Self.white))
        XCTAssertEqual(color.lookLine?.author, "gia")
        XCTAssertEqual(custom.lookLine?.change, .appearance(.custom, background: .dawn))
        XCTAssertNil(renamed.lookLine)
        XCTAssertNil(said.lookLine)
    }

    func testTheRoomKeepsEachLineOnceInTheOrderTheChangesWereMade() throws {
        // Arrange
        let early = try entry("look:gia:1", rev: 3, at: Self.at, extra: ["change": .string("photo")])
        let late = try entry("look:franco:2", rev: 9, author: "franco", at: Self.at + 60_000, extra: ["change": .string("color"), "ring": .null])
        let page = try historyPage(["looks": .array([try entryJSON(late)])])
        var thread = RoomThread(.family)

        // Act
        thread.load(page)
        thread.apply(early)
        thread.apply(late)

        // Assert
        XCTAssertEqual(thread.lookLines.map(\.id), ["look:gia:1", "look:franco:2"])
    }

    func testAPageFromAGatewayWithNoLookStillReads() throws {
        // Arrange, Act
        let page = try historyPage([:])

        // Assert
        XCTAssertNil(page.looks)
        XCTAssertNil(page.familyLook)
    }

    func testEachLineSitsAmongTheMessagesAtItsTime() throws {
        // Arrange
        var thread = RoomThread(.family)
        thread.apply(try message("m-1", rev: 1, at: Self.at))
        thread.apply(try entry("look:gia:1", rev: 2, at: Self.at + 30_000, extra: ["change": .string("photo")]))
        thread.apply(try message("m-2", rev: 3, at: Self.at + 60_000))
        thread.apply(try entry("look:gia:2", rev: 4, at: Self.at + 90_000, extra: ["change": .string("color"), "ring": Self.whiteJSON]))

        // Act
        let rows = ThreadRow.rows(
            of: thread,
            me: RoomSelf(person: "franco", assistant: "corey"),
            assistants: ["corey", "denise"],
            typing: [],
            activity: nil,
            readying: [],
            shared: [],
            isConnected: true,
            lifted: nil
        )

        // Assert
        let order = rows.map { row -> String in
            switch row.content {
            case .message(let content):
                return content.message.id
            case .look(let line):
                return line.id
            default:
                return "other"
            }
        }
        XCTAssertEqual(order, ["m-1", "look:gia:1", "m-2", "look:gia:2"])
    }

    /// An entry back as the gateway's JSON, for a page.
    private func entryJSON(_ entry: RoomEntry) throws -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(entry.id), "rev": .number(Double(entry.rev)), "kind": .string(entry.kind.rawValue),
            "conversation": .string(entry.conversation), "author": .string(entry.author),
            "at": .number(Double(entry.at)), "origin": .string("peer"),
        ]
        switch entry.lookChange {
        case .photo:
            members["change"] = .string("photo")
        case .color(let ring):
            members["change"] = .string("color")
            members["ring"] = ring.map { .object(["red": .number($0.red), "green": .number($0.green), "blue": .number($0.blue)]) } ?? .null
        case .appearance(let appearance, let background):
            members["change"] = .string("appearance")
            members["appearance"] = .string(appearance.rawValue)
            members["background"] = background.map { .string($0.rawValue) } ?? .null
        case nil:
            break
        }
        return .object(members)
    }
}
