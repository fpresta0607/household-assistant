// The Today card at the top of Chats, from the phone's side: `household-app.today`'s answer
// and the plugin's `today` event in the shape the plugin gives them, what the card shows as
// the day passes, and the copy kept on the phone, which shows with no gateway at all.
// Driven over a scripted gateway, in the household's own time zone.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class TodayTests: XCTestCase {
    /// A connected gateway that answers `household-app.today` from a closure.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var answer: ((GatewayRequest) -> String)?

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
                } else if request.method == "household-app.today", let answer = self?.answer {
                    transport.push(answer(request))
                }
            }
        }

        var reads: Int {
            transport.requests.filter { $0.method == "household-app.today" }.count
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

    /// The household: Chicago in October, five hours behind UTC, given as an offset so no
    /// time zone database is needed, read in American English.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// Thursday 15 October 2026 at `hour`:`minute` in the household, or a day later.
    private func at(_ hour: Int, _ minute: Int = 0, daysLater: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_792_040_400 + Double(daysLater * 86_400 + hour * 3_600 + minute * 60))
    }

    private nonisolated static let todays = """
        {"day":"2026-10-15","at":1792064700000,"items":[
        {"start":"2026-10-15T07:45:00-05:00","title":"School drop off","detail":"Leave by 7:30, the roads are light"},
        {"start":"2026-10-15T09:00:00-05:00","title":"Dentist"},
        {"start":"2026-10-15T12:30:00-05:00","title":"Lunch with Gia"},
        {"start":"2026-10-15T17:45:00-05:00","title":"Soccer pickup"},
        {"start":"2026-10-16T08:00:00-05:00","title":"Soccer"}],
        "verse":{"text":"Be still, and know that I am God.","reference":"Psalm 46:10",
        "link":"https://www.bible.com/bible/3034/PSA.46.10.BSB"}}
        """

    private func card(_ json: String = todays) throws -> TodayCard {
        try JSONDecoder().decode(TodayCard.self, from: Data(json.utf8))
    }

    private static func ok(_ request: GatewayRequest, _ payload: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":true,"payload":\#(payload)}"#
    }

    private func event(_ payload: String) throws -> GatewayEvent {
        GatewayEvent(event: TodayCard.eventName, payload: try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)), seq: 7)
    }

    private func archive() -> RoomArchive {
        let archive = RoomArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        addTeardownBlock { archive.forget() }
        return archive
    }

    private func eventually(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var attemptsLeft = 400
        while attemptsLeft > 0, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
    }

    // MARK: - What the gateway answers

    func testTheMethodsAnswerDecodesInThePluginsShape() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answer = { Self.ok($0, #"{"today":\#(Self.todays)}"#) }
        try await gateway.connect()

        // Act
        let today = try await gateway.connection.today().decoded(as: TodayCard.self)

        // Assert
        XCTAssertEqual(today.day, "2026-10-15")
        XCTAssertEqual(today.items.count, 5)
        XCTAssertEqual(today.items.first?.detail, "Leave by 7:30, the roads are light")
        XCTAssertFalse(today.items[1].allDay, "an item that does not say is not all day")
        XCTAssertEqual(today.items.first?.startDate, at(7, 45))
        XCTAssertEqual(today.verse?.link?.absoluteString, "https://www.bible.com/bible/3034/PSA.46.10.BSB")
        XCTAssertEqual(gateway.transport.requests.last?.method, "household-app.today")
    }

    func testAGatewayWithNoCardAnswersNull() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answer = { Self.ok($0, #"{"today":null}"#) }
        try await gateway.connect()

        // Act
        let today = try await gateway.connection.today()

        // Assert
        XCTAssertEqual(today, .null)
    }

    func testAVerseLinkThatIsNotTheBibleAppsOpensNothing() async throws {
        for link in ["https://example.com/PSA.46.10", "http://www.bible.com/bible/3034/PSA.46.10.BSB", "not a link"] {
            // Arrange
            let json = Self.todays.replacingOccurrences(of: "https://www.bible.com/bible/3034/PSA.46.10.BSB", with: link)

            // Act
            let verse = try card(json).verse

            // Assert
            XCTAssertNil(verse?.link, link)
            XCTAssertEqual(verse?.reference, "Psalm 46:10", "the verse itself still shows")
        }
    }

    // MARK: - What the card shows as the day passes

    func testTheMorningShowsTheNextThingFirstWithTwoMore() async throws {
        // Act
        let glance = try XCTUnwrap(TodayGlance(card: card(), at: at(6, 45), calendar: calendar))

        // Assert
        XCTAssertEqual(glance.heading, .today)
        XCTAssertEqual(glance.next?.title, "School drop off")
        XCTAssertEqual(glance.next?.time, "7:45")
        XCTAssertEqual(glance.next?.detail, "Leave by 7:30, the roads are light")
        XCTAssertEqual(glance.more.map(\.title), ["Dentist", "Lunch with Gia"])
        XCTAssertEqual(glance.more.map(\.time), ["9:00", "12:30"])
        XCTAssertEqual(glance.verse?.reference, "Psalm 46:10")
    }

    func testSomethingJustStartedIsStillNextForAQuarterOfAnHour() async throws {
        // Act
        let under = try XCTUnwrap(TodayGlance(card: card(), at: at(9, 10), calendar: calendar))
        let after = try XCTUnwrap(TodayGlance(card: card(), at: at(9, 15), calendar: calendar))

        // Assert
        XCTAssertEqual(under.next?.title, "Dentist")
        XCTAssertEqual(after.next?.title, "Lunch with Gia", "a quarter of an hour in, it is no longer next")
        XCTAssertEqual(after.more.map(\.title), ["Soccer pickup", "Soccer"])
    }

    func testTheEveningSaysTonightAndNamesTomorrowsDay() async throws {
        // Act
        let glance = try XCTUnwrap(TodayGlance(card: card(), at: at(17, 10), calendar: calendar))

        // Assert
        XCTAssertEqual(glance.heading, .tonight)
        XCTAssertEqual(glance.next?.title, "Soccer pickup")
        XCTAssertEqual(glance.next?.time, "5:45")
        XCTAssertEqual(glance.more.map(\.time), ["Fri 8:00"])
    }

    func testOnlyTheDaysOwnVerseShows() async throws {
        // Act
        let tomorrowMorning = try XCTUnwrap(TodayGlance(card: card(), at: at(7, 0, daysLater: 1), calendar: calendar))

        // Assert
        XCTAssertNil(tomorrowMorning.verse, "yesterday's verse is not this morning's")
        XCTAssertEqual(tomorrowMorning.next?.title, "Soccer", "what is still ahead shows all the same")
        XCTAssertEqual(tomorrowMorning.next?.time, "8:00")
    }

    func testWithNothingAheadOnlyTheVerseIsLeftAndThenNothing() async throws {
        // Arrange
        let late = try card("""
            {"day":"2026-10-15","at":0,"items":[{"start":"2026-10-15T09:00:00-05:00","title":"Dentist"}],
            "verse":{"text":"Be still, and know that I am God.","reference":"Psalm 46:10"}}
            """)

        // Act
        let tonight = try XCTUnwrap(TodayGlance(card: late, at: at(21, 0), calendar: calendar))
        let tomorrow = TodayGlance(card: late, at: at(6, 0, daysLater: 1), calendar: calendar)

        // Assert
        XCTAssertNil(tonight.next)
        XCTAssertTrue(tonight.more.isEmpty)
        XCTAssertEqual(tonight.verse?.reference, "Psalm 46:10")
        XCTAssertNil(tomorrow, "with nothing ahead and no verse for the day, the card goes")
    }

    func testSomethingAllDayIsAheadUntilItsDayEnds() async throws {
        // Arrange
        let json = """
            {"day":"2026-10-15","at":0,"items":[
            {"start":"2026-10-15T00:00:00-05:00","title":"Trash day","allDay":true},
            {"start":"2026-10-16T00:00:00-05:00","title":"Book fair","allDay":true}]}
            """

        // Act
        let evening = try XCTUnwrap(TodayGlance(card: card(json), at: at(22, 0), calendar: calendar))
        let lines = TodayGlance.lines(of: try card(json), at: at(22, 0), calendar: calendar)

        // Assert
        XCTAssertEqual(evening.next?.title, "Trash day")
        XCTAssertNil(evening.next?.time, "all of today needs no time")
        XCTAssertEqual(evening.more.first?.time, "Fri")
        XCTAssertEqual(lines.map(\.isPast), [false, false])
    }

    func testTheCardMovesOnWhenSomethingStopsBeingNextTheEveningComesOrTheDayEnds() async throws {
        // Arrange
        let today = try card()

        // Act and assert
        XCTAssertEqual(TodayGlance.nextChange(of: today, after: at(6, 45), calendar: calendar), at(8, 0), "a quarter of an hour after 7:45")
        XCTAssertEqual(TodayGlance.nextChange(of: today, after: at(12, 50), calendar: calendar), at(17, 0), "the evening")
        XCTAssertEqual(TodayGlance.nextChange(of: today, after: at(18, 30), calendar: calendar), at(0, daysLater: 1), "the day's end")
    }

    func testTheWholeDayDimsWhatHasGoneBy() async throws {
        // Act
        let lines = TodayGlance.lines(of: try card(), at: at(10, 0), calendar: calendar)

        // Assert
        XCTAssertEqual(lines.map(\.title), ["School drop off", "Dentist", "Lunch with Gia", "Soccer pickup", "Soccer"])
        XCTAssertEqual(lines.map(\.isPast), [true, true, false, false, false])
    }

    // MARK: - Kept on the phone

    func testAKeptCardShowsAtOnceWithNoGateway() async throws {
        // Arrange
        let kept = archive()
        kept.writeToday(try JSONDecoder().decode(JSONValue.self, from: Data(Self.todays.utf8)))
        let gateway = Gateway()

        // Act
        let model = TodayModel(connection: gateway.connection, archive: kept, now: { [unowned self] in self.at(6, 45) }, calendar: calendar)

        // Assert
        XCTAssertEqual(model.glance?.next?.title, "School drop off")
        XCTAssertEqual(model.lines.count, 5)
        XCTAssertEqual(gateway.reads, 0, "shown from the phone, before the gateway is asked")
    }

    func testWhatTheGatewaySendsIsKeptAndANullForgetsIt() async throws {
        // Arrange
        let kept = archive()
        let gateway = Gateway()
        gateway.answer = { Self.ok($0, #"{"today":\#(Self.todays)}"#) }
        try await gateway.connect()
        let model = TodayModel(connection: gateway.connection, archive: kept, now: { [unowned self] in self.at(6, 45) }, calendar: calendar)

        // Act
        await model.refresh()

        // Assert
        XCTAssertEqual(model.glance?.next?.title, "School drop off")
        let reread = TodayModel(connection: gateway.connection, archive: kept, now: { [unowned self] in self.at(6, 45) }, calendar: calendar)
        XCTAssertEqual(reread.glance, model.glance, "the next start shows the same card from the phone")

        // Act
        model.handle(try event(#"{"today":null}"#))

        // Assert
        XCTAssertNil(model.glance)
        XCTAssertNil(kept.readToday(), "a card the gateway no longer has is not kept either")
    }

    func testANewCardFromTheEventReplacesTheOneShowing() async throws {
        // Arrange
        let model = TodayModel(connection: Gateway().connection, archive: nil, now: { [unowned self] in self.at(6, 45) }, calendar: calendar)
        let evening = Self.todays.replacingOccurrences(of: "School drop off", with: "Choir")

        // Act
        model.handle(try event(#"{"today":\#(Self.todays)}"#))
        model.handle(try event(#"{"today":\#(evening)}"#))

        // Assert
        XCTAssertEqual(model.glance?.next?.title, "Choir")
    }

    func testSomethingThatIsNotACardLeavesTheOneShowing() async throws {
        // Arrange
        let model = TodayModel(connection: Gateway().connection, archive: nil, now: { [unowned self] in self.at(6, 45) }, calendar: calendar)
        model.handle(try event(#"{"today":\#(Self.todays)}"#))

        // Act
        model.handle(try event(#"{"today":{"day":"2026-10-15"}}"#))
        model.handle(GatewayEvent(event: "plugin.household-app.brief", payload: .object(["brief": .null]), seq: 8))

        // Assert
        XCTAssertEqual(model.glance?.next?.title, "School drop off")
    }

    // MARK: - Folded to a banner once seen

    /// Where the phone keeps when the whole card was last seen, here in memory.
    private final class SeenStore: TodaySeenStore {
        var todaySeenAt: Date?
        var todaySeenVerseDay: String?
    }

    /// A model showing the day's card at `moment`'s time, which a test moves on.
    private func seenModel(_ seen: SeenStore, at moment: @escaping () -> Date) throws -> TodayModel {
        let model = TodayModel(connection: Gateway().connection, archive: nil, seen: seen, now: moment, calendar: calendar)
        model.handle(try event(#"{"today":\#(Self.todays)}"#))
        return model
    }

    func testTheCardIsWholeTheFirstTimeEachDayAndABannerOnceSeen() throws {
        // Arrange
        let seen = SeenStore()
        let model = try seenModel(seen) { [unowned self] in self.at(6, 45) }
        XCTAssertFalse(model.isFolded, "whole the first time today")

        // Act
        model.markSeen()

        // Assert
        XCTAssertTrue(model.isFolded)
        XCTAssertEqual(seen.todaySeenAt, at(6, 45), "kept on the phone")
        let relaunched = try seenModel(seen) { [unowned self] in self.at(12, 30) }
        XCTAssertTrue(relaunched.isFolded, "still a banner later the same day, after the app starts again")
    }

    func testTheBannerOpensTheWholeCardUntilItIsSeenAgain() throws {
        // Arrange
        let model = try seenModel(SeenStore()) { [unowned self] in self.at(6, 45) }
        model.markSeen()

        // Act
        model.open()

        // Assert
        XCTAssertFalse(model.isFolded, "the whole card again on a tap")
        model.markSeen()
        XCTAssertTrue(model.isFolded, "a banner again once it is left or checked off")
    }

    func testTheNextMorningTheCardIsWholeAgain() throws {
        // Arrange
        let seen = SeenStore()
        seen.todaySeenAt = at(22, 10)

        // Act
        let model = try seenModel(seen) { [unowned self] in self.at(6, 45, daysLater: 1) }

        // Assert
        XCTAssertFalse(model.isFolded)
    }

    func testAnOvernightVisitDoesNotConsumeTheMorning() throws {
        let seen = SeenStore()
        var moment = at(0, 20)
        let model = try seenModel(seen) { moment }
        model.markSeen()
        XCTAssertTrue(model.isFolded)
        moment = at(4, 59)
        model.updateClock()
        XCTAssertTrue(model.isFolded)
        moment = at(5)
        model.updateClock()
        XCTAssertFalse(model.isFolded)
        model.markSeen()
        XCTAssertTrue(model.isFolded)
    }

    func testAFoldedBannerDoesNotKeepMovingTheSeenTime() throws {
        let seen = SeenStore()
        var moment = at(6)
        let model = try seenModel(seen) { moment }
        model.markSeen()
        moment = at(23)
        model.markSeen()
        XCTAssertEqual(seen.todaySeenAt, at(6))
    }

    func testAVerseArrivingAfterTheCalendarOpensOnceAndStaysSeenAfterRelaunch() throws {
        let seen = SeenStore()
        let model = try seenModel(seen) { [unowned self] in self.at(6, 26) }
        var json = try JSONSerialization.jsonObject(with: Data(Self.todays.utf8)) as! [String: Any]
        json.removeValue(forKey: "verse")
        let noVerse = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        model.handle(try event(#"{"today":\#(noVerse)}"#))
        model.markSeen()
        XCTAssertTrue(model.isFolded)
        XCTAssertNil(seen.todaySeenVerseDay)
        model.handle(try event(#"{"today":\#(Self.todays)}"#))
        XCTAssertFalse(model.isFolded, "the calendar being read does not mark an unseen verse read")
        model.markSeen()
        XCTAssertEqual(seen.todaySeenVerseDay, "2026-10-15")
        let relaunched = try seenModel(seen) { [unowned self] in self.at(9) }
        XCTAssertTrue(relaunched.isFolded)
    }

    func testChicagoMorningAcrossBothDaylightSavingChanges() throws {
        var central = Calendar(identifier: .gregorian)
        central.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let iso = ISO8601DateFormatter()
        for (before, after, expected) in [
            ("2026-03-08T04:59:00-05:00", "2026-03-08T05:00:00-05:00", "2026-03-07T05:00:00-06:00"),
            ("2026-11-01T04:59:00-06:00", "2026-11-01T05:00:00-06:00", "2026-10-31T05:00:00-05:00"),
        ] {
            let early = try XCTUnwrap(iso.date(from: before))
            let morning = try XCTUnwrap(iso.date(from: after))
            XCTAssertEqual(TodayGlance.morning(containing: early, calendar: central), iso.date(from: expected))
            XCTAssertEqual(TodayGlance.morning(containing: morning, calendar: central), morning)
        }
        XCTAssertEqual(TodayGlance.nextChange(of: try card(), after: at(4, 59), calendar: calendar), at(5))
    }

    func testForgettingTheAssistantForgetsWhenItsCardWasSeen() throws {
        // Arrange
        let seen = SeenStore()
        let model = try seenModel(seen) { [unowned self] in self.at(6, 45) }
        model.markSeen()

        // Act
        model.reset()

        // Assert
        XCTAssertNil(seen.todaySeenAt)
        XCTAssertFalse(model.isFolded)
    }

    func testForgettingTheAssistantForgetsItsDay() async throws {
        // Arrange
        let kept = archive()
        kept.writeToday(try JSONDecoder().decode(JSONValue.self, from: Data(Self.todays.utf8)))
        let model = TodayModel(connection: Gateway().connection, archive: kept, now: { [unowned self] in self.at(6, 45) }, calendar: calendar)

        // Act
        model.reset()

        // Assert
        XCTAssertNil(model.glance)
        XCTAssertTrue(model.lines.isEmpty)
        XCTAssertNil(kept.readToday())
    }
}
