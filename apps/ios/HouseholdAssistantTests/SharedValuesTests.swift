#if canImport(UIKit)
// One value behind every surface that edits it: the assistant's name renamed on its page is
// the name on Settings, every other page and the widgets; a ring picked with Edit Color
// from one photo menu is the ring on the assistant's page, Settings, the room and the
// widgets; a photo chosen on the contact page is the face Settings and the room show; and the
// Fam's look changed on either phone is the one look both read, a line in the room for each.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class SharedValuesTests: XCTestCase {
    func testARenameOnTheAssistantsPageIsTheNameOnEveryOtherPageAndTheWidgets() async throws {
        // Arrange
        let gateway = FixtureGateway()
        await gateway.connect()
        await gateway.model.assistantSettings.load()
        XCTAssertEqual(gateway.model.assistantName, "Corey")

        // Act
        await gateway.model.assistantSettings.change(.name, to: "Hoot")

        // Assert
        XCTAssertEqual(gateway.model.assistantSettings.name, "Hoot")
        XCTAssertEqual(gateway.model.assistantName, "Hoot")
        await gateway.eventually("the widgets renamed") { WidgetSnapshot.load().assistantName == "Hoot" }
    }

    func testARingPickedFromOnePhotoMenuIsTheRingEverywhereAndInTheWidgets() async throws {
        // Arrange
        let gateway = FixtureGateway()
        await gateway.connect()
        let assistant = try XCTUnwrap(gateway.model.room.me?.assistant)
        let rose = RingColor(red: 0.95, green: 0.4, blue: 0.55)

        // Act: Edit Color in either of the contact page's photo menus keeps it here.
        gateway.model.settings.assistantRings[assistant] = rose

        // Assert
        XCTAssertEqual(gateway.model.assistantRing, rose)
        await gateway.eventually("the widgets ringed") { WidgetSnapshot.load().face(assistant)?.ring == rose }
        let launched = AppSettings(defaults: .standard)
        XCTAssertEqual(launched.assistantRings[assistant], rose)
    }

    func testTheFamsLookSetOnOnePhoneIsTheLookOnTheOtherWithALineForEachChange() async throws {
        // Arrange
        let gateway = FixtureGateway()
        await gateway.connect()
        let white = RingColor(red: 1, green: 1, blue: 1)

        // Act: this phone picks the color, and Gia's phone, over the relay, the night.
        try await gateway.model.room.setFamilyColor(white)
        _ = gateway.room.add(DemoRoom.Entry(
            id: "look:gia:1",
            kind: "look",
            conversation: .family,
            author: "gia",
            at: Int(Date().timeIntervalSince1970 * 1000) + 1000,
            look: ["change": .string("appearance"), "appearance": .string("custom"), "background": .string("night")]
        ))
        await gateway.changed()

        // Assert
        XCTAssertEqual(gateway.model.room.familyLook, FamilyLook(ring: white, appearance: .custom, background: .night))
        XCTAssertEqual(gateway.model.room.thread(.family).lookLines.map(\.author), ["franco", "gia"])
    }

    func testAPhotoChosenOnTheContactPageIsTheFaceSettingsAndTheRoomShow() async throws {
        // Arrange
        let gateway = FixtureGateway()
        await gateway.connect()
        let assistant = try XCTUnwrap(gateway.model.room.me?.assistant)
        let hash = String(repeating: "e", count: 64)
        let face = #"{"id":"\#(hash)","kind":"photo","mime":"image/jpeg","bytes":2048,"width":512,"height":512}"#
        gateway.answers["household-app.upload"] = { request in
            let total = request.params["total"]?.intValue ?? 0
            return try FixtureGateway.ok(request, JSONDecoder().decode(
                JSONValue.self,
                from: Data(#"{"complete":true,"received":\#(total),"id":"\#(hash)","bytes":\#(total)}"#.utf8)
            ))
        }
        gateway.answers["household-app.avatar.set"] = { request in
            try FixtureGateway.ok(request, JSONDecoder().decode(
                JSONValue.self,
                from: Data(#"{"participants":[{"id":"\#(assistant)","name":"Corey","kind":"assistant","isOwner":false,"avatar":\#(face)}]}"#.utf8)
            ))
        }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 2044)

        // Act
        try await gateway.model.room.setFace(of: assistant, jpeg: jpeg, side: 512)

        // Assert: Settings' row reads assistantPhoto, and the contact page and the room read the
        // room's participant.
        XCTAssertEqual(gateway.model.assistantPhoto?.id, hash)
        XCTAssertEqual(gateway.model.room.participant(assistant)?.avatar?.id, hash)
    }
}
#endif
