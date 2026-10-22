// Which carts a newer one has replaced, worked out once for the whole thread: every older
// cart with an id gives way and the newest is the cart as it is now, only an assistant's
// cart replaces one, a cart still arriving counts once its block has closed, and a cart in
// a message the gateway has not kept is never replaced.

import XCTest
@testable import HouseholdAssistant

final class CartReplacementsTests: XCTestCase {
    private static let assistants: Set<String> = ["corey", "denise"]

    private static func cart(_ id: String) -> String {
        "```steward-card\n{\"type\":\"cart\",\"id\":\"\(id)\",\"items\":[],\"skill\":\"lists\"}\n```"
    }

    private func message(_ id: String, rev: Int?, author: String = "corey", text: String, status: RoomMessage.Status = .sent) -> RoomMessage {
        RoomMessage(
            id: id,
            author: author,
            text: text,
            media: [],
            replyTo: nil,
            sentAt: Date(timeIntervalSince1970: 1_792_018_800),
            status: status,
            rev: rev
        )
    }

    func testEveryOlderCartWithTheSameIdGivesWayAndTheNewestDoesNot() {
        let messages = [
            message("m-1", rev: 1, text: "Added candles.\n\n" + Self.cart("household")),
            message("m-2", rev: 2, author: "gia", text: "Thanks Corey"),
            message("m-3", rev: 3, author: "denise", text: "Added soap.\n\n" + Self.cart("household")),
            message("m-4", rev: 4, text: Self.cart("household") + "\n" + Self.cart("party")),
        ]

        let replacements = CartReplacements(messages: messages, assistants: Self.assistants)

        XCTAssertEqual(replacements.carts(replacedIn: "m-1"), ["household"])
        XCTAssertEqual(replacements.carts(replacedIn: "m-2"), [])
        XCTAssertEqual(replacements.carts(replacedIn: "m-3"), ["household"])
        XCTAssertEqual(replacements.carts(replacedIn: "m-4"), [], "the newest is the cart as it is now")
    }

    func testACartWithAnotherIdIsNotReplaced() {
        let messages = [
            message("m-1", rev: 1, text: Self.cart("household")),
            message("m-2", rev: 2, text: Self.cart("party")),
        ]

        let replacements = CartReplacements(messages: messages, assistants: Self.assistants)

        XCTAssertEqual(replacements.carts(replacedIn: "m-1"), [])
    }

    func testOnlyAnAssistantsCartReplacesOne() {
        let messages = [
            message("m-1", rev: 1, text: Self.cart("household")),
            // Somebody pasting a card's block writes text, which the room shows as text.
            message("m-2", rev: 2, author: "gia", text: Self.cart("household")),
        ]

        let replacements = CartReplacements(messages: messages, assistants: Self.assistants)

        XCTAssertEqual(replacements.carts(replacedIn: "m-1"), [])
    }

    func testACartStillArrivingReplacesTheOlderOnceItsBlockHasClosed() {
        let older = message("m-1", rev: 1, text: Self.cart("household"))
        let newer = Self.cart("household")
        let open = message("run:run-9", rev: nil, text: "Ordered.\n\n" + newer.dropLast(4), status: .streaming)
        let closed = message("run:run-9", rev: nil, text: "Ordered.\n\n" + newer, status: .streaming)

        let whileOpen = CartReplacements(messages: [older, open], assistants: Self.assistants)
        let onceClosed = CartReplacements(messages: [older, closed], assistants: Self.assistants)

        XCTAssertEqual(whileOpen.carts(replacedIn: "m-1"), [])
        XCTAssertEqual(onceClosed.carts(replacedIn: "m-1"), ["household"])
    }

    func testACartTheGatewayHasNotKeptIsNeverReplaced() {
        let messages = [
            message("run:run-7", rev: nil, text: Self.cart("household")),
            message("m-8", rev: 8, text: Self.cart("household")),
        ]

        let replacements = CartReplacements(messages: messages, assistants: Self.assistants)

        XCTAssertEqual(replacements.carts(replacedIn: "run:run-7"), [])
    }

    func testAThreadWithoutCartsReplacesNothing() {
        let messages = [
            message("m-1", rev: 1, text: "Dinner is at 6:30."),
            message("m-2", rev: 2, author: "gia", text: "Thanks"),
        ]

        let replacements = CartReplacements(messages: messages, assistants: Self.assistants)

        XCTAssertEqual(replacements, CartReplacements(messages: [], assistants: Self.assistants))
    }
}
