// The household's shared cart and the buyer's order, as Daisy's gateway sends them
// (Protocol/Fixtures/cards): what each card reads, the newest cart taking the older one's
// place, and an order never drawn in the family room.

import XCTest
@testable import HouseholdAssistant

final class CartCardTests: XCTestCase {
    private func block(_ json: String) -> String {
        "```steward-card\n\(json)\n```"
    }

    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> StewardCard {
        let found = StewardCardParser.segments(in: block(json), isStreaming: false)
        XCTAssertEqual(found.count, 1, "\(found)", file: file, line: line)
        var card: StewardCard?
        if case .card(let only)? = found.first {
            card = only
        }
        return try XCTUnwrap(card, "\(found)", file: file, line: line)
    }

    private func entry(_ id: String, rev: Int, author: String = "corey", text: String) throws -> RoomEntry {
        try JSONValue.object([
            "id": .string(id), "rev": .number(Double(rev)), "kind": .string("message"),
            "conversation": .string("family"), "author": .string(author),
            "at": .number(1_792_018_800_000), "origin": .string("local"),
            "text": .string(text), "media": .array([]),
        ]).decoded(as: RoomEntry.self)
    }

    private static let assistants: Set<String> = ["corey", "denise"]

    private static func cartBlock(_ items: String) -> String {
        "```steward-card\n{\"type\":\"cart\",\"id\":\"household\",\"items\":[\(items)],\"skill\":\"lists\"}\n```"
    }

    private static let candles = #"{"id":"ci-90ad3e44","name":"Birthday candles","quantity":1,"by":"Corey","for":"Franco"}"#

    // MARK: - The cart

    func testDaisysCartReadsEveryItemWithWhoAddedItAndWhoItIsFor() throws {
        let cart = try card(try Fixtures.text("cards/cart"))

        XCTAssertEqual(cart.skill, .lists)
        XCTAssertEqual(cart.content, .cart(CartCard(
            id: "household",
            title: "Household cart",
            items: [
                CartCard.Item(
                    id: "ci-7f3a9c2e",
                    name: "Paper towels, 12 rolls",
                    quantity: 1,
                    by: "Denise",
                    forPerson: "Gia",
                    url: URL(string: "https://www.amazon.com/dp/B07XYZ1234"),
                    image: URL(string: "https://m.media-amazon.com/images/I/71example.jpg")
                ),
                CartCard.Item(id: "ci-1b84d0f6", name: "Dish soap, 3 pack", quantity: 1, by: "Denise", forPerson: "Gia", url: URL(string: "https://www.amazon.com/dp/B08ABC5678"), image: nil),
                CartCard.Item(id: "ci-c2e95a17", name: "Coffee filters #4", quantity: 2, by: "Corey", forPerson: "Franco", url: URL(string: "https://www.amazon.com/dp/B000DEF901"), image: nil),
                CartCard.Item(id: "ci-90ad3e44", name: "Birthday candles", quantity: 1, by: "Corey", forPerson: "Franco", url: nil, image: nil),
            ],
            checkout: URL(string: "https://www.amazon.com/gp/aws/cart/add.html?ASIN.1=B07XYZ1234&Quantity.1=1&ASIN.2=B08ABC5678&Quantity.2=1&ASIN.3=B000DEF901&Quantity.3=2")
        )))
    }

    func testACartWithNothingLeftInItIsStillACart() throws {
        let empty = try card(#"{"type":"cart","id":"household","title":"Household cart","items":[],"skill":"lists"}"#)

        XCTAssertEqual(empty.content, .cart(CartCard(id: "household", title: "Household cart", items: [], checkout: nil)))
        XCTAssertEqual(empty.skill, .lists, "a cart wears the lists badge even without naming it")
    }

    func testACartWithALinkThatIsNotHttpsOrAnItemMissingWhatItNeedsIsShownAsItsJSON() {
        let cards = [
            #"{"type":"cart","id":"household","items":[],"checkout":"http://www.amazon.com/gp/aws/cart/add.html"}"#,
            #"{"type":"cart","id":"household","items":[{"id":"ci-1","name":"Soap","quantity":1,"by":"Denise","for":"Gia","url":"amazon://dp/B08ABC5678"}]}"#,
            #"{"type":"cart","id":"household","items":[{"id":"ci-1","name":"Soap","quantity":1,"by":"Denise","for":"Gia","image":"http://m.media-amazon.com/soap.jpg"}]}"#,
            #"{"type":"cart","id":"household","items":[{"id":"ci-1","name":"Soap","quantity":0,"by":"Denise","for":"Gia"}]}"#,
            #"{"type":"cart","id":"household","items":[{"id":"ci-1","name":"","quantity":1,"by":"Denise","for":"Gia"}]}"#,
            #"{"type":"cart","id":"household","items":[{"id":"ci-1","name":"Soap","quantity":1,"for":"Gia"}]}"#,
            #"{"type":"cart","id":"","items":[]}"#,
        ]
        for json in cards {
            XCTAssertEqual(StewardCardParser.segments(in: block(json), isStreaming: false), [.code(json)], json)
        }
    }

    func testACartReadsAsItsItemsWhenCopied() throws {
        let text = "Added candles.\n\n" + block(try Fixtures.text("cards/cart"))

        XCTAssertEqual(MessagePlainText.text(of: text, calendar: .current), """
        Added candles.

        Household cart
        1 Paper towels, 12 rolls, for Gia, added by Denise
        1 Dish soap, 3 pack, for Gia, added by Denise
        2 Coffee filters #4, for Franco, added by Corey
        1 Birthday candles, for Franco, added by Corey
        """)
    }

    // MARK: - The newest cart in place of the older

    func testANewerCartWithTheSameIdTakesTheOlderOnesPlace() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1, text: "Added candles.\n\n" + Self.cartBlock(Self.candles)))
        thread.apply(try entry("m-2", rev: 2, author: "gia", text: "Thanks Corey"))
        thread.apply(try entry("m-3", rev: 3, author: "denise", text: "Added soap.\n\n" + Self.cartBlock(Self.candles)))

        XCTAssertTrue(thread.isCartReplaced("household", in: "m-1", assistants: Self.assistants))
        XCTAssertFalse(thread.isCartReplaced("household", in: "m-3", assistants: Self.assistants), "the newest is the cart as it is now")
        XCTAssertFalse(thread.isCartReplaced("another-cart", in: "m-1", assistants: Self.assistants))
    }

    func testOnlyAnAssistantsCartReplacesOne() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1, text: Self.cartBlock(Self.candles)))
        // Somebody pasting a card's block writes text, which the room shows as text.
        thread.apply(try entry("m-2", rev: 2, author: "gia", text: Self.cartBlock("")))

        XCTAssertFalse(thread.isCartReplaced("household", in: "m-1", assistants: Self.assistants))
    }

    func testACartStillArrivingReplacesTheOlderOnceItsBlockHasClosed() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1, text: Self.cartBlock(Self.candles)))
        let newer = Self.cartBlock("")

        thread.stream(runId: "run-9", author: "corey", text: "Ordered.\n\n" + newer.dropLast(4), replace: true)
        XCTAssertFalse(thread.isCartReplaced("household", in: "m-1", assistants: Self.assistants))

        thread.stream(runId: "run-9", author: "corey", text: "Ordered.\n\n" + newer, replace: true)
        XCTAssertTrue(thread.isCartReplaced("household", in: "m-1", assistants: Self.assistants))
    }

    // MARK: - The order

    func testDaisysOrderReadsItsProgressArrivalAndMaskedNumber() throws {
        let order = try card(try Fixtures.text("cards/order"))
        guard case .order(let progress) = order.content else {
            return XCTFail("not an order: \(order)")
        }

        XCTAssertEqual(order.skill, .lists)
        XCTAssertEqual(progress.title, "Household order")
        XCTAssertEqual(progress.items, 3)
        XCTAssertEqual(progress.status, .shipped)
        XCTAssertEqual(progress.arriving, DateComponents(year: 2026, month: 10, day: 16))
        XCTAssertEqual(progress.order, "113-***-4417")
        XCTAssertEqual(progress.steps, [
            OrderCard.Step(label: "Ordered", at: Date(timeIntervalSince1970: 1_792_021_320)),
            OrderCard.Step(label: "Shipped", at: Date(timeIntervalSince1970: 1_792_059_000)),
            OrderCard.Step(label: "Out for delivery", at: nil),
            OrderCard.Step(label: "Delivered", at: nil),
        ])
        XCTAssertEqual(progress.reached, 2)
    }

    func testAnOrderTappedOrderedHasNoNumberOrArrivalYet() throws {
        let tapped = try card(#"{"type":"order","title":"Household order","items":2,"status":"ordered","steps":[{"label":"Ordered","at":"2026-10-15T09:12:00-04:00"},{"label":"Shipped"},{"label":"Out for delivery"},{"label":"Delivered"}],"skill":"lists"}"#)
        guard case .order(let order) = tapped.content else {
            return XCTFail("not an order: \(tapped)")
        }

        XCTAssertNil(order.order)
        XCTAssertNil(order.arriving)
        XCTAssertEqual(order.reached, 1)
    }

    func testADeliveredOrderHasReachedEveryStepEvenOnesNoEmailDated() throws {
        let delivered = try card(#"{"type":"order","title":"Household order","items":1,"status":"delivered","steps":[{"label":"Ordered","at":"2026-10-14T19:42:00-04:00"},{"label":"Shipped"},{"label":"Out for delivery"},{"label":"Delivered","at":"2026-10-16T14:02:00-04:00"}]}"#)
        guard case .order(let order) = delivered.content else {
            return XCTFail("not an order: \(delivered)")
        }

        XCTAssertEqual(order.reached, 4)
    }

    func testAnOrderMissingWhatItNeedsIsShownAsItsJSON() {
        let cards = [
            #"{"type":"order","title":"Household order","items":3,"status":"lost","steps":[{"label":"Ordered"}]}"#,
            #"{"type":"order","title":"Household order","items":3,"status":"ordered","steps":[]}"#,
            #"{"type":"order","title":"Household order","items":3,"status":"ordered","arriving":"Friday","steps":[{"label":"Ordered"}]}"#,
            #"{"type":"order","title":"Household order","items":3,"status":"ordered","arriving":"2026-02-30","steps":[{"label":"Ordered"}]}"#,
            #"{"type":"order","title":"Household order","items":3,"status":"ordered","steps":[{"label":"Ordered","at":"yesterday"}]}"#,
            #"{"type":"order","title":"Household order","items":-1,"status":"ordered","steps":[{"label":"Ordered"}]}"#,
        ]
        for json in cards {
            XCTAssertEqual(StewardCardParser.segments(in: block(json), isStreaming: false), [.code(json)], json)
        }
    }

    func testAnOrderIsDrawnOnlyInTheBuyersOwnThread() throws {
        let order = try card(try Fixtures.text("cards/order"))
        let cart = try card(try Fixtures.text("cards/cart"))

        XCTAssertTrue(order.content.isShown(in: .direct))
        XCTAssertFalse(order.content.isShown(in: .family), "an order that arrives in the family room is refused")
        XCTAssertTrue(cart.content.isShown(in: .family))
        XCTAssertTrue(cart.content.isShown(in: .direct))
    }

    func testAnOrderReadsAsItsProgressWhenCopied() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        calendar.locale = Locale(identifier: "en_US")

        XCTAssertEqual(MessagePlainText.text(of: block(try Fixtures.text("cards/order")), calendar: calendar), """
        Household order, 3 items: Shipped
        Arriving Friday, October 16, 2026
        Order 113-***-4417
        """)
    }
}
