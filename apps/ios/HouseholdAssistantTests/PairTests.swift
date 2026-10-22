// The Corey & Denise group from the phone's side: `household-app.pair`'s page, the plugin's
// `pair` event and the `pair` mark on the room's pages in the shapes the plugin gives them,
// the rule that folds a burst of rows into one line, what each line says, how long the
// family room's marker shows, and the model reading the line a page at a time over a
// scripted gateway.
//
// The pair fixtures were written by the plugin's own notes.js, driven the way
// tests/js/household_app_notes.test.mjs drives it, with invented words.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class PairTests: XCTestCase {
    /// A connected gateway that answers each method from a closure.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var answers: [String: (GatewayRequest) -> String] = [:]

        init() {
            let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
            let signer = DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "connect-signature" }
            connection = GatewayConnection(transport: transport, credentials: store, signer: signer) { _ in
                await Task.yield()
            }
            transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
            transport.onRequest = { [weak self] transport, request in
                if request.method == "connect" {
                    transport.push((try? Fixtures.text("hello-ok-device-token", answering: request.id)) ?? "")
                } else if let answer = self?.answers[request.method] {
                    transport.push(answer(request))
                }
            }
        }

        func requests(_ method: String) -> [GatewayRequest] {
            transport.requests.filter { $0.method == method }
        }

        func connect() async throws {
            connection.start(GatewayConnection.Configuration(
                url: URL(string: "ws://127.0.0.1:18800")!,
                client: .stewardPhone(displayName: "test", version: "0.1.0"),
                scopes: OperatorScope.chat,
                locale: "en-US"
            ))
            var attemptsLeft = 400
            while attemptsLeft > 0, connection.state != .connected {
                try await Task.sleep(for: .milliseconds(5))
                attemptsLeft -= 1
            }
            XCTAssertEqual(connection.state, .connected)
        }
    }

    private static let names = ["corey": "Corey", "denise": "Denise", "franco": "Franco", "gia": "Gia"]

    private static func ok(_ request: GatewayRequest, _ payload: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":true,"payload":\#(payload)}"#
    }

    private static func refused(_ request: GatewayRequest, _ message: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"\#(message)"}}"#
    }

    private static func fixturePayload(_ name: String) -> String {
        guard
            let text = try? Fixtures.text(name),
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let payload = object["payload"],
            let data = try? JSONSerialization.data(withJSONObject: payload)
        else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// One step as the plugin pages it: a row Corey logged in Seedlings, unless said.
    private static func step(_ number: Int, at: Int, by: String = "corey", kind: String = "added", topic: String = "Seedlings") -> String {
        #"{"id":"ns-\#(number)","at":\#(at),"by":"\#(by)","kind":"\#(kind)","for":"franco","line":{"id":"hn-\#(number)","topic":"\#(topic)","text":"\#(number) cm"}}"#
    }

    private static func page(_ steps: [String], more: Bool) -> String {
        #"{"events":[\#(steps.joined(separator: ","))],"more":\#(more)}"#
    }

    private static func decoded(_ json: String) throws -> PairEvent {
        try JSONDecoder().decode(PairEvent.self, from: Data(json.utf8))
    }

    private static func pairEvent(lastAt: Int, seq: Int) -> GatewayEvent {
        GatewayEvent(event: PairPage.eventName, payload: .object(["lastAt": .number(Double(lastAt))]), seq: seq)
    }

    private func payload(_ name: String) throws -> JSONValue {
        guard case .response(let response) = try GatewayCodec.decode(try Fixtures.text(name)) else {
            throw XCTSkip("not a response")
        }
        return try XCTUnwrap(response.payload)
    }

    private func fixturePage() throws -> PairPage {
        try payload("household-app-pair-response").decoded(as: PairPage.self)
    }

    private func eventually(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var attemptsLeft = 400
        while attemptsLeft > 0, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
    }

    // MARK: - What the gateway sends

    func testThePageDecodesEveryKindInThePluginsShape() throws {
        // Act
        let page = try fixturePage()

        // Assert
        XCTAssertFalse(page.more)
        XCTAssertEqual(page.events.map(\.kind), [.added, .added, .added, .corrected, .handed, .seen, .replied, .done, .claimed, .tookOver, .removed])
        XCTAssertEqual(page.events.map(\.by), ["corey", "corey", "corey", "corey", "corey", "denise", "denise", "denise", "corey", "denise", "corey"])
        XCTAssertEqual(page.events[0].takenAt, Date(timeIntervalSince1970: 1_792_504_930))
        XCTAssertEqual(page.events[3].line?.item, "Basil")
        XCTAssertEqual(page.events[3].line?.text, "5 cm")
        let handed = page.events[4]
        XCTAssertEqual(handed.forWho, "franco")
        XCTAssertEqual(handed.line?.topic, "Handoffs")
        XCTAssertEqual(handed.line?.owner, "denise")
        XCTAssertNil(handed.line?.item)
        XCTAssertNil(page.events[5].forWho, "a sighting is for nobody")
        XCTAssertEqual(page.events[6].reply, "Two are due Friday, the rest next week.")
        XCTAssertEqual(page.events[8].forWho, "franco")
        XCTAssertEqual(page.events[8].message, "m-00000001")
        XCTAssertNil(page.events[8].line, "a claim changes no line")
        XCTAssertEqual(page.events[9].message, "m-00000001")
        XCTAssertNil(page.events[9].forWho, "a takeover names only the message")
    }

    func testThePairEventSaysWhenTheLineLastMoved() throws {
        // Act
        guard case .event(let event) = try GatewayCodec.decode(try Fixtures.text("household-app-pair-event")) else {
            return XCTFail("not an event")
        }

        // Assert
        XCTAssertEqual(event.event, PairPage.eventName)
        XCTAssertEqual(event.payload?["lastAt"]?.intValue, try fixturePage().events.last?.at)
    }

    func testAKindALaterGatewayAddsAndALineThatDoesNotReadStillDecodeAsPlainLines() throws {
        // Arrange
        let json = #"""
            {"events":[
            {"id":"ns-1","at":1,"by":"corey","kind":"pinned","line":{"id":"hn-1","topic":"Seedlings","text":"Water at dusk"}},
            {"id":"ns-2","at":2,"by":"denise","kind":"waved"},
            {"id":"ns-3","at":3,"by":"corey","kind":"added","line":{"topic":7}}],
            "more":false}
            """#

        // Act
        let page = try JSONDecoder().decode(PairPage.self, from: Data(json.utf8))
        let words = PairEntry.entries(of: page.events).map { $0.words(names: Self.names) }

        // Assert
        XCTAssertEqual(page.events.map(\.kind), [.other("pinned"), .other("waved"), .added])
        XCTAssertNil(page.events[2].line, "a line that does not read is no line")
        XCTAssertEqual(words, [
            "Corey changed Seedlings: \u{201C}Water at dusk\u{201D}",
            "Denise did something this version cannot show",
            "Corey changed the household note",
        ])
    }

    func testEveryRoomPageSaysWhenTheLineLastMovedOnceItHasAnyStep() throws {
        // Arrange
        let marked = try Fixtures.text("household-app-sync-response", answering: "fixture-sync") { frame in
            var payload = frame["payload"] as? [String: Any] ?? [:]
            payload["pair"] = ["lastAt": 1_792_505_832_000]
            frame["payload"] = payload
        }
        guard case .response(let response) = try GatewayCodec.decode(marked) else {
            return XCTFail("not a response")
        }

        // Act
        let page = try XCTUnwrap(response.payload).decoded(as: RoomSyncPage.self)

        // Assert
        XCTAssertEqual(page.pair, RoomPair(lastAt: 1_792_505_832_000))
        XCTAssertNil(try payload("household-app-sync-response").decoded(as: RoomSyncPage.self).pair, "a line with no step yet")
        XCTAssertNil(try payload("household-app-history-response").decoded(as: RoomHistoryPage.self).pair)
    }

    // MARK: - The group's lines

    func testEachLineSaysWhatHappenedInPlainWords() throws {
        // Act
        let entries = PairEntry.entries(of: try fixturePage().events)

        // Assert
        let library = "\u{201C}Can you check whether the library books are due this week?\u{201D}"
        XCTAssertEqual(entries.map { $0.words(names: Self.names) }, [
            "Corey logged 3 rows in Seedlings",
            "Corey corrected Basil in Seedlings: \u{201C}5 cm\u{201D}",
            "Corey handed Denise: \(library)",
            "Denise saw it",
            "Denise replied: \u{201C}Two are due Friday, the rest next week.\u{201D}",
            "Denise marked done: \(library)",
            "Corey took Franco's question",
            "Denise took over Franco's question",
            "Corey removed Chives from Seedlings: \u{201C}6 cm\u{201D}",
        ])
        XCTAssertEqual(entries.map(\.detail), ["Basil 4 cm, Thyme 2 cm, Chives 6 cm", nil, nil, library, library, nil, nil, nil, nil])
        XCTAssertEqual(entries[0].id, "ns-00000000-0000-4000-8000-000000000001", "a burst is known by its first row")
    }

    func testATakeoverWhoseClaimIsNotHereNamesNobodyAndAnUnknownNameIsItsId() throws {
        // Arrange
        let events = [try Self.decoded(#"{"id":"ns-1","at":1,"by":"denise","kind":"tookOver","message":"m-1"}"#)]

        // Act
        let words = PairEntry.entries(of: events).map { $0.words(names: [:]) }

        // Assert
        XCTAssertEqual(words, ["denise took over a question"])
    }

    func testABurstIsRowsByOneAssistantToOneTopicWithinASecondOfItsFirst() throws {
        // Arrange: each case's steps as (at, by, kind, topic), and the rows each line holds.
        let cases: [(why: String, steps: [(Int, String, String, String)], lines: [Int])] = [
            ("rows in the same moment", [(0, "corey", "added", "Seedlings"), (1, "corey", "added", "Seedlings"), (2, "corey", "added", "Seedlings")], [3]),
            ("rows spread within the second", [(0, "corey", "added", "Seedlings"), (600, "corey", "added", "Seedlings"), (999, "corey", "added", "Seedlings")], [3]),
            ("a row a second after the first", [(0, "corey", "added", "Seedlings"), (1_000, "corey", "added", "Seedlings")], [1, 1]),
            ("a row close to the one before but not to the first", [(0, "corey", "added", "Seedlings"), (600, "corey", "added", "Seedlings"), (1_200, "corey", "added", "Seedlings")], [2, 1]),
            ("rows to another topic", [(0, "corey", "added", "Seedlings"), (1, "corey", "added", "Groceries")], [1, 1]),
            ("rows by the other assistant", [(0, "corey", "added", "Seedlings"), (1, "denise", "added", "Seedlings")], [1, 1]),
            ("a correction between rows", [(0, "corey", "added", "Seedlings"), (1, "corey", "corrected", "Seedlings"), (2, "corey", "added", "Seedlings")], [1, 1, 1]),
            ("corrections in the same moment", [(0, "corey", "corrected", "Seedlings"), (1, "corey", "corrected", "Seedlings")], [1, 1]),
            ("no steps", [], []),
        ]

        for (why, steps, lines) in cases {
            // Act
            let events = try steps.enumerated().map { index, step in
                try Self.decoded(Self.step(index + 1, at: step.0, by: step.1, kind: step.2, topic: step.3))
            }
            let entries = PairEntry.entries(of: events)

            // Assert
            XCTAssertEqual(entries.map(\.events.count), lines, why)
        }
    }

    func testTheMarkerShowsForAnHourAfterTheLineLastMoved() {
        // Arrange
        let lastAt = 1_792_505_832_000
        let moment = Date(timeIntervalSince1970: 1_792_505_832)
        let cases: [(seconds: TimeInterval, words: String?)] = [
            (-30, "just now"),
            (0, "just now"),
            (59, "just now"),
            (60, "1 min ago"),
            (4 * 60 + 30, "4 min ago"),
            (3_599, "59 min ago"),
            (3_600, nil),
            (86_400, nil),
        ]

        for (seconds, words) in cases {
            // Act
            let shown = PairRecency.words(lastAt: lastAt, now: moment.addingTimeInterval(seconds))

            // Assert
            XCTAssertEqual(shown, words, "\(seconds) s after")
        }
    }

    // MARK: - Reading the line

    func testTheNewestPageShowsWithABurstAsOneLine() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.pair"] = { Self.ok($0, Self.fixturePayload("household-app-pair-response")) }
        try await gateway.connect()
        let pair = PairModel(connection: gateway.connection)

        // Act
        await pair.refresh()

        // Assert
        XCTAssertEqual(pair.events.count, 11)
        XCTAssertEqual(pair.entries.count, 9)
        XCTAssertFalse(pair.hasOlder)
        let asked = try XCTUnwrap(gateway.requests("household-app.pair").first)
        XCTAssertNil(asked.params["before"], "the newest page")
        XCTAssertEqual(asked.params["limit"]?.intValue, 100)
    }

    func testScrollingUpReadsThePageBeforeTheOldestStepUntilNoneAreOlder() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.pair"] = { request in
            request.params["before"]?.intValue == 3_000
                ? Self.ok(request, Self.page([Self.step(1, at: 1_000, kind: "corrected"), Self.step(2, at: 2_000, kind: "removed")], more: false))
                : Self.ok(request, Self.page([Self.step(3, at: 3_000, kind: "corrected"), Self.step(4, at: 4_000, kind: "corrected")], more: true))
        }
        try await gateway.connect()
        let pair = PairModel(connection: gateway.connection)
        await pair.refresh()
        XCTAssertTrue(pair.hasOlder)

        // Act
        await pair.loadOlder()
        await pair.loadOlder()

        // Assert
        XCTAssertEqual(pair.events.map(\.id), ["ns-1", "ns-2", "ns-3", "ns-4"])
        XCTAssertFalse(pair.hasOlder)
        XCTAssertEqual(gateway.requests("household-app.pair").map { $0.params["before"]?.intValue }, [nil, 3_000], "nothing older is asked for")
    }

    func testThePairEventReadsTheNewestPageAgainKeepingTheOlderOnes() async throws {
        // Arrange: the newest page, then the one before it as the person scrolled up.
        let gateway = Gateway()
        gateway.answers["household-app.pair"] = { request in
            request.params["before"] == nil
                ? Self.ok(request, Self.page([Self.step(3, at: 3_000, kind: "corrected")], more: true))
                : Self.ok(request, Self.page([Self.step(1, at: 1_000, kind: "corrected")], more: false))
        }
        try await gateway.connect()
        let pair = PairModel(connection: gateway.connection)
        await pair.refresh()
        await pair.loadOlder()
        gateway.answers["household-app.pair"] = { request in
            Self.ok(request, Self.page([Self.step(3, at: 3_000, kind: "corrected"), Self.step(4, at: 4_000, kind: "handed")], more: true))
        }

        // Act
        pair.handle(Self.pairEvent(lastAt: 4_000, seq: 9))

        // Assert
        await eventually("the new step") { pair.events.count == 3 }
        XCTAssertEqual(pair.events.map(\.id), ["ns-1", "ns-3", "ns-4"])
        XCTAssertFalse(pair.hasOlder, "the oldest page read still has nothing before it")
    }

    func testANewestPageThatLeavesAGapReplacesWhatIsHere() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.pair"] = { Self.ok($0, Self.page([Self.step(1, at: 1_000, kind: "corrected"), Self.step(2, at: 2_000, kind: "corrected")], more: false)) }
        try await gateway.connect()
        let pair = PairModel(connection: gateway.connection)
        await pair.refresh()
        gateway.answers["household-app.pair"] = { Self.ok($0, Self.page([Self.step(5, at: 5_000, kind: "corrected"), Self.step(6, at: 6_000, kind: "corrected")], more: true)) }

        // Act
        await pair.refresh()

        // Assert
        XCTAssertEqual(pair.events.map(\.id), ["ns-5", "ns-6"])
        XCTAssertTrue(pair.hasOlder, "what lay between is read again as the person scrolls up")
    }

    func testAGatewayWithNoLineLeavesTheGroupEmptyAndPairingAgainForgetsIt() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.pair"] = { Self.refused($0, "unknown method: household-app.pair") }
        try await gateway.connect()
        let pair = PairModel(connection: gateway.connection)

        // Act
        await pair.refresh()
        let fromAnOlderGateway = pair.entries
        gateway.answers["household-app.pair"] = { Self.ok($0, Self.fixturePayload("household-app-pair-response")) }
        await pair.refresh()
        pair.reset()

        // Assert
        XCTAssertEqual(fromAnOlderGateway, [])
        XCTAssertEqual(pair.events, [])
        XCTAssertEqual(pair.entries, [])
        XCTAssertFalse(pair.hasOlder)
    }

    // MARK: - The family room's marker

    func testTheRoomsPagesAndThePairEventSayWhenTheLineLastMovedOnlyEverLater() async throws {
        // Arrange
        let gateway = Gateway()
        let orientation = #""participants":[{"id":"franco","name":"Franco","kind":"person","isOwner":true},{"id":"corey","name":"Corey","kind":"assistant","isOwner":false}],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{"family":"agent:main:household:group:family","direct":"agent:main:household:direct:franco"}"#
        gateway.answers["household-app.history"] = { request in
            Self.ok(request, #"{"messages":[],"hasMore":false,"reactions":{},"reads":[],\#(orientation),"pair":{"lastAt":5000}}"#)
        }
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, #"{"entries":[],"rev":0,"hasMore":false,\#(orientation),"pair":{"lastAt":4000}}"#)
        }
        try await gateway.connect()
        let room = RoomModel(connection: gateway.connection, sign: { _ in "signature" })

        // Act
        await room.refresh()
        let fromThePages = room.pairLastAt
        room.handle(Self.pairEvent(lastAt: 3_000, seq: 1))
        let afterAnEarlierEvent = room.pairLastAt
        room.handle(Self.pairEvent(lastAt: 9_000, seq: 2))

        // Assert
        XCTAssertEqual(fromThePages, 5_000, "the sync page read after does not take it back")
        XCTAssertEqual(afterAnEarlierEvent, 5_000)
        XCTAssertEqual(room.pairLastAt, 9_000)
        XCTAssertEqual(room.names, ["franco": "Franco", "corey": "Corey"])
    }
}
