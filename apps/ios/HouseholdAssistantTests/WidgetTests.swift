// The widgets: the links they open the app with, and the snapshot the app writes for
// them from the room as this phone holds it.

import XCTest
@testable import HouseholdAssistant

final class WidgetTests: XCTestCase {
    // MARK: - Links

    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text), text)
    }

    func testEachPlaceInTheAppHasALinkThatOpensThatPlace() {
        let places: [AppLink] = [
            .conversation(.family), .conversation(.direct), .write(.family), .write(.direct), .record(.family), .record(.direct), .talk,
        ]
        for place in places {
            XCTAssertEqual(AppLink(url: place.url), place, place.url.absoluteString)
        }
        XCTAssertEqual(Set(places.map(\.url)).count, places.count, "no two places share a link")
    }

    func testTheLinksAreTheOnesTheWidgetsAndTheTalkControlOpen() {
        XCTAssertEqual(AppLink.conversation(.family).url.absoluteString, "steward://family")
        XCTAssertEqual(AppLink.conversation(.direct).url.absoluteString, "steward://direct")
        XCTAssertEqual(AppLink.write(.family).url.absoluteString, "steward://family/write")
        XCTAssertEqual(AppLink.write(.direct).url.absoluteString, "steward://direct/write")
        XCTAssertEqual(AppLink.record(.family).url.absoluteString, "steward://family/record")
        XCTAssertEqual(AppLink.record(.direct).url.absoluteString, "steward://direct/record")
        XCTAssertEqual(AppLink.talk.url.absoluteString, "steward://talk")
    }

    func testALinkIsReadWhateverItsCaseAndATrailingSlash() throws {
        XCTAssertEqual(AppLink(url: try url("STEWARD://Talk")), .talk)
        XCTAssertEqual(AppLink(url: try url("steward://family/")), .conversation(.family))
        XCTAssertEqual(AppLink(url: try url("steward://Direct/Write")), .write(.direct))
        XCTAssertEqual(AppLink(url: try url("steward://Family/Record/")), .record(.family))
    }

    func testComingBackFromLinkingPocketPiggiesOpensThePersonsOwnConversation() throws {
        XCTAssertEqual(AppLink(url: try url("steward://pocketpiggies/linked?request=req-1")), .conversation(.direct))
        XCTAssertEqual(AppLink(url: try url("steward://PocketPiggies/Linked/")), .conversation(.direct))
        XCTAssertNil(AppLink(url: try url("steward://pocketpiggies")))
        XCTAssertNil(AppLink(url: try url("steward://pocketpiggies/unlinked")))
    }

    func testAnythingElseIsNoPlaceInTheApp() throws {
        for text in [
            "steward://",
            "steward://chat",
            "steward://telegram",
            "steward://pair?code=abc",
            "steward://talk/now",
            "steward://family/read",
            "steward://family/write/now",
            "steward://family/record/now",
            "steward://talk/record",
            "https://family",
            "stewards://talk",
            "steward:talk",
        ] {
            XCTAssertNil(AppLink(url: try url(text)), text)
        }
    }

    // MARK: - The snapshot

    private static let household = [
        RoomParticipant(id: "gia", name: "Rosa", kind: .person, isOwner: false),
        RoomParticipant(id: "corey", name: "Corey", kind: .assistant, isOwner: false, emoji: "\u{1F989}"),
        RoomParticipant(id: "franco", name: "Leo", kind: .person, isOwner: true),
        RoomParticipant(
            id: "denise",
            name: "Denise",
            kind: .assistant,
            isOwner: false,
            emoji: "\u{1F338}",
            avatar: RoomMedia(id: String(repeating: "d", count: 64), kind: .photo, mime: "image/jpeg", bytes: 10)
        ),
    ]

    func testARingPickedForAnAssistantReachesTheWidgetsAndOnlyForAssistants() {
        // Arrange
        let rose = RingColor(red: 0.82, green: 0.24, blue: 0.47)
        var snapshot = WidgetSnapshot()

        // Act
        snapshot.show(
            family: RoomThread(.family),
            direct: RoomThread(.direct),
            participants: Self.household,
            me: RoomSelf(person: "franco", assistant: "corey"),
            rings: ["corey": rose, "franco": rose]
        )

        // Assert
        XCTAssertEqual(snapshot.face("corey")?.ring, rose)
        XCTAssertNil(snapshot.face("denise")?.ring, "an assistant with no ring picked stays gold")
        XCTAssertNil(snapshot.face("franco")?.ring, "a person's face has no assistant's ring")
    }

    func testASnapshotWrittenBeforeRingsStillReads() throws {
        // Arrange
        let older = #"{"id":"corey","name":"Corey","isAssistant":true,"isOwner":false,"emoji":"🦉","hasPhoto":false}"#

        // Act
        let face = try JSONDecoder().decode(WidgetSnapshot.Face.self, from: Data(older.utf8))

        // Assert
        XCTAssertEqual(face.name, "Corey")
        XCTAssertNil(face.ring)
    }

    private func snapshot(
        family: RoomThread = RoomThread(.family),
        direct: RoomThread = RoomThread(.direct)
    ) -> WidgetSnapshot {
        var snapshot = WidgetSnapshot()
        snapshot.show(family: family, direct: direct, participants: Self.household, me: RoomSelf(person: "franco", assistant: "corey"))
        return snapshot
    }

    private func entry(
        _ id: String,
        rev: Int,
        kind: String = "message",
        conversation: String = "family",
        author: String,
        text: String? = "hello",
        extra: [String: JSONValue] = [:]
    ) throws -> RoomEntry {
        var members: [String: JSONValue] = [
            "id": .string(id), "rev": .number(Double(rev)), "kind": .string(kind),
            "conversation": .string(conversation), "author": .string(author),
            "at": .number(1_792_018_800_000 + Double(rev) * 60_000), "origin": .string("local"),
        ]
        if let text {
            members["text"] = .string(text)
            members["media"] = .array([])
        }
        for (key, value) in extra {
            members[key] = value
        }
        return try JSONValue.object(members).decoded(as: RoomEntry.self)
    }

    private func read(_ messageId: String, by author: String, rev: Int) throws -> RoomEntry {
        try entry("read:family:\(author)", rev: rev, kind: "read", author: author, text: nil, extra: ["messageId": .string(messageId)])
    }

    private func media(_ kind: String, _ letter: Character, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(String(repeating: letter, count: 64)),
            "kind": .string(kind),
            "mime": .string("application/octet-stream"),
            "bytes": .number(10),
        ]
        for (key, value) in extra {
            members[key] = value
        }
        return .object(members)
    }

    func testTheWidgetsShowTheNewestLinesTheGatewayKeptAndHowManyAreUnread() throws {
        var family = RoomThread(.family)
        for (index, author) in ["franco", "gia", "corey", "gia", "denise", "franco", "gia"].enumerated() {
            family.apply(try entry("m-\(index + 1)", rev: index + 1, author: author, text: "line \(index + 1)"))
        }
        family.apply(try read("m-2", by: "franco", rev: 8))
        var direct = RoomThread(.direct)
        direct.apply(try entry("d-1", rev: 9, conversation: "direct", author: "franco", text: "Remind me to leave at 5:30"))
        direct.apply(try entry("a-1", rev: 10, conversation: "direct", author: "corey", text: "Done. I will remind you at 5:30 PM"))

        let shown = snapshot(family: family, direct: direct)

        XCTAssertEqual(shown.family.lines.map(\.id), ["m-3", "m-4", "m-5", "m-6", "m-7"], "the newest five, oldest first")
        XCTAssertEqual(shown.family.lines.last?.author, "gia")
        XCTAssertEqual(shown.family.lines.last?.text, "line 7")
        XCTAssertEqual(shown.family.lines.last?.sentAt, family.messages.last?.sentAt)
        XCTAssertEqual(shown.family.unread, 4, "everything after Leo's read marker but his own")
        XCTAssertEqual(shown.direct.lines.map(\.text), ["Remind me to leave at 5:30", "Done. I will remind you at 5:30 PM"])
        XCTAssertEqual(shown.direct.unread, 1)
        XCTAssertEqual(shown.conversation(.family), shown.family)
        XCTAssertEqual(shown.conversation(.direct), shown.direct)
        XCTAssertEqual(shown.me, "franco")
        XCTAssertEqual(shown.assistant, "corey")
    }

    /// The widgets reload only when what they show changes, so none of these reloads one.
    func testASendOnItsWayOrAReplyStillStreamingChangesNothingTheWidgetsShow() throws {
        var direct = RoomThread(.direct)
        direct.apply(try entry("a-1", rev: 1, conversation: "direct", author: "corey", text: "Morning"))
        let before = snapshot(direct: direct)

        direct.addPending(RoomMessage(id: "d-2", author: "franco", text: "On my way", media: [], replyTo: nil, sentAt: Date(), status: .sending))
        direct.stream(runId: "run-1", author: "corey", text: "Tonight is pasta", replace: false)

        XCTAssertEqual(snapshot(direct: direct), before)
    }

    func testAReactionOrSomebodyElseReadingChangesNothingButThisPersonReadingDoes() throws {
        var family = RoomThread(.family)
        family.apply(try entry("m-1", rev: 1, author: "gia", text: "Dinner is ready"))
        let before = snapshot(family: family)

        family.apply(try entry("reaction:m-1:corey", rev: 2, kind: "reaction", author: "corey", text: nil,
                               extra: ["messageId": .string("m-1"), "emoji": .string("\u{1F44D}")]))
        family.apply(try read("m-1", by: "gia", rev: 3))
        XCTAssertEqual(snapshot(family: family), before)

        family.apply(try read("m-1", by: "franco", rev: 4))
        XCTAssertEqual(snapshot(family: family).family.unread, 0)
        XCTAssertNotEqual(snapshot(family: family), before)
    }

    func testALineIsTheMessagesWordsOrWhatWasSent() throws {
        let photo = media("photo", "a")
        let voice = media("voice", "b", ["durationMs": .number(6_000)])
        let file = media("file", "c", ["name": .string("Field trip permission slip.pdf")])
        var family = RoomThread(.family)
        family.apply(try entry("m-1", rev: 1, author: "gia", text: "", extra: ["media": .array([photo])]))
        family.apply(try entry("m-2", rev: 2, author: "gia", text: " \n", extra: ["media": .array([voice])]))
        family.apply(try entry("m-3", rev: 3, author: "corey", text: "Here it is.", extra: ["media": .array([file])]))
        family.apply(try entry("m-4", rev: 4, author: "corey", text: "", extra: ["media": .array([media("file", "e")])]))
        family.apply(try entry("m-5", rev: 5, author: "gia", text: "Dinner\n\n  is   ready \u{1F35D} "))

        let lines = snapshot(family: family).family.lines

        XCTAssertEqual(lines.map(\.text), ["Photo", "Voice note \u{00B7} 0:06", "Here it is.", "File", "Dinner is ready \u{1F35D}"])
        XCTAssertEqual(lines.map(\.symbol), ["photo", "waveform", nil, "doc.fill", nil])
    }

    func testAnAssistantsCardsAreLeftOutOfItsLineAndACardOnItsOwnSaysWhatItIsAbout() throws {
        let checklist = "```steward-card\n{\"type\":\"checklist\",\"id\":\"shopping\",\"title\":\"Shopping list\",\"items\":[{\"text\":\"Milk\",\"done\":false}]}\n```"
        let event = "```steward-card\n{\"type\":\"event\",\"title\":\"Movie night\",\"start\":\"2026-10-16T20:00:00-04:00\"}\n```"
        // Whatever it holds, a gate code included, is not put on the Lock Screen.
        let code = "```steward-card\n{\"type\":\"copy\",\"text\":\"4821\"}\n```"
        var direct = RoomThread(.direct)
        direct.apply(try entry("a-1", rev: 1, conversation: "direct", author: "corey", text: "Here is **Saturday**.\n\n" + checklist))
        direct.apply(try entry("a-2", rev: 2, conversation: "direct", author: "corey", text: checklist + "\n\n" + event))
        direct.apply(try entry("a-3", rev: 3, conversation: "direct", author: "corey", text: event))
        direct.apply(try entry("a-4", rev: 4, conversation: "direct", author: "corey", text: code))

        XCTAssertEqual(
            snapshot(direct: direct).direct.lines.map(\.text),
            ["Here is **Saturday**.", "Shopping list", "Movie night", "Something to copy"]
        )
    }

    func testASermonOrASearchsSourcesOnTheirOwnSayWhatTheyAre() throws {
        let sermon = "```steward-card\n{\"type\":\"sermon\",\"title\":\"Love that gives\",\"quote\":\"Love gives.\"}\n```"
        let sources = "```steward-card\n{\"type\":\"sources\",\"links\":[{\"url\":\"https://news.example/pool\"}]}\n```"
        var direct = RoomThread(.direct)
        direct.apply(try entry("a-1", rev: 1, conversation: "direct", author: "corey", text: sermon))
        direct.apply(try entry("a-2", rev: 2, conversation: "direct", author: "corey", text: sources))

        XCTAssertEqual(snapshot(direct: direct).direct.lines.map(\.text), ["Love that gives", "Sources"])
    }

    func testALongLineIsCutWhereNoWidgetShowsMore() throws {
        var direct = RoomThread(.direct)
        direct.apply(try entry("a-1", rev: 1, conversation: "direct", author: "corey", text: String(repeating: "word ", count: 100)))

        let text = try XCTUnwrap(snapshot(direct: direct).direct.lines.first?.text)

        XCTAssertEqual(text.count, WidgetSnapshot.lineLength)
        XCTAssertTrue(text.hasSuffix("\u{2026}"))
    }

    func testEveryoneIsSeatedTheWayTheRoomsCircleSeatsThemWithWhatTheirFaceIsMadeOf() {
        let shown = snapshot()

        XCTAssertEqual(shown.faces.map(\.id), ["franco", "corey", "denise", "gia"])
        XCTAssertEqual(shown.faces.map(\.isAssistant), [false, true, true, false])
        XCTAssertEqual(shown.faces.map(\.isOwner), [true, false, false, false])
        XCTAssertEqual(shown.faces.map(\.emoji), [nil, "\u{1F989}", "\u{1F338}", nil])
        XCTAssertEqual(shown.faces.map(\.hasPhoto), [false, false, true, false])
        XCTAssertEqual(shown.face("gia")?.name, "Rosa")
        XCTAssertNil(shown.face("telegram"))
    }

    func testTheRoomsCircleSeatsThisPhonesPersonFirstAndTheAssistantsOnTheOtherDiagonal() {
        XCTAssertEqual(FamilyFaces.arranged(Self.household).map(\.id), ["franco", "corey", "denise", "gia"])
        XCTAssertEqual(FamilyFaces.arranged(Array(Self.household.prefix(2))).map(\.id), ["gia", "corey"])
        XCTAssertEqual(FamilyFaces.arranged([]).map(\.id), [])
    }

    /// The app writes it and the widget reads it, each in its own process.
    func testTheSnapshotReadsBackInTheWidgetAsTheAppWroteIt() throws {
        var family = RoomThread(.family)
        family.apply(try entry("m-1", rev: 1, author: "gia", text: "", extra: ["media": .array([media("photo", "a")])]))
        family.apply(try entry("m-2", rev: 2, author: "denise", text: "Rosa's flight lands at 4:10"))
        var written = snapshot(family: family)
        written.assistantName = "Corey"
        written.assistantEmoji = "\u{1F989}"

        let read = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(written))

        XCTAssertEqual(read, written)
    }

    #if canImport(UIKit)
    /// The widget extension names the notifications' folder itself rather than compile the
    /// push key's file for it, so the two must not drift apart.
    func testTheWidgetsReadTheFacesFromWhereTheAppDrawsThemForTheNotifications() {
        XCTAssertEqual(WidgetFacePhotos.folder, NotificationFolder.url)
    }
    #endif
}
