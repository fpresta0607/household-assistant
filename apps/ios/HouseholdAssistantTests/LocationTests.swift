// Sharing where this phone is: off until its person turns it on, with whom and for how
// long they choose, paused or stopped from Settings, over by itself when its time is up,
// and told to their own gateway sparingly and signed, driven over a scripted gateway.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class LocationTests: XCTestCase {
    /// A connected gateway that keeps every location report, or refuses them while told to.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var isRefusing = false
        private(set) var signed: [String] = []

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
                } else if self?.isRefusing == true {
                    transport.push(#"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"UNAVAILABLE","message":"the household app could not do that"}}"#)
                } else {
                    transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"sharing":"assistant"}}"#)
                }
            }
        }

        func sign(_ text: String) -> String {
            signed.append(text)
            return "phone-signature-\(signed.count)"
        }

        var reports: [JSONValue] {
            transport.requests.filter { $0.method == "household-app.location" }.map(\.params)
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

    @MainActor
    private final class Store: LocationSharingStore {
        var locationSharing: LocationSharing?
        var isLocationHeldByGateway = false
        var isLocationPrecise = true
    }

    /// 5:51:59 PM in Indianapolis on 15 October 2026.
    private var clock = Date(timeIntervalSince1970: 1_792_101_119)

    private static let indianapolis: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        return calendar
    }()

    /// Franco on Maple Street, measured a minute ago.
    private func fix(
        _ latitude: Double = 39.768403,
        _ longitude: Double = -86.158068,
        accuracy: Double = 64.2,
        secondsAgo: TimeInterval = 59,
        isVisit: Bool = false
    ) -> LocationFix {
        LocationFix(latitude: latitude, longitude: longitude, accuracy: accuracy, at: clock - secondsAgo, isVisit: isVisit)
    }

    private func sharer(_ gateway: Gateway, _ store: Store) -> LocationSharingModel {
        LocationSharingModel(connection: gateway.connection, sign: gateway.sign, store: store, now: { self.clock }, calendar: Self.indianapolis)
    }

    private static let stopped: [String: JSONValue] = ["sharing": .string("off"), "until": .null, "position": .null]

    // MARK: - What the phone signs

    func testTheSignedTextIsTheOneTheGatewayChecks() {
        let report = LocationReport(
            at: 1_792_101_119_000,
            audience: .assistant,
            until: 1_792_104_720_000,
            position: LocationReport.Position(latitudeE6: 39_768_403, longitudeE6: -86_158_068, accuracy: 65, at: 1_792_101_060_000)
        )

        XCTAssertEqual(report.signedText, "household-app/location/v1\n1792101119000\nassistant\n1792104720000\n1792101060000\n39768403\n-86158068\n65")
        XCTAssertEqual(LocationReport.stop(at: 1_792_101_120_000).signedText, "household-app/location/v1\n1792101120000\noff\n\n\n\n\n")
    }

    func testAPositionTravelsInWholeUnits() {
        let measured = LocationFix(latitude: 39.7684034, longitude: -86.1580676, accuracy: 64.2, at: Date(timeIntervalSince1970: 1_792_101_060.4))

        XCTAssertEqual(measured.position, LocationReport.Position(latitudeE6: 39_768_403, longitudeE6: -86_158_068, accuracy: 65, at: 1_792_101_060_400))
    }

    // MARK: - When Always is asked

    func testAlwaysIsAskedWhenSomethingMustGoOnWithTheAppClosed() {
        // Sharing that lasts, with the assistant or the family, in the first run or Settings.
        for span in LocationSpan.allCases {
            XCTAssertTrue(LocationAlwaysAsk.isAsked(at: .sharingTurnedOn(span)), "\(span)")
        }
        // A map in a chat: live for any time, but not shared once.
        XCTAssertFalse(LocationAlwaysAsk.isAsked(at: .mapShared(.once)))
        for span in [MapShareSpan.quarterHour, .hour, .endOfDay] {
            XCTAssertTrue(LocationAlwaysAsk.isAsked(at: .mapShared(span)), "\(span)")
        }
        // A reminder by place, the person's own or one they said yes to.
        XCTAssertTrue(LocationAlwaysAsk.isAsked(at: .placeReminderSet))
    }

    func testSettingsSaysSharingPausesWithTheAppClosedOnlyWhenItDoes() {
        let sharing = LocationSharing(audience: .family, span: .tonight, from: clock, calendar: Self.indianapolis)
        var paused = sharing
        paused.isPaused = true

        XCTAssertEqual(
            LocationAlwaysAsk.closedAppNote(sharing: sharing, isAlways: false, at: clock),
            "It pauses when Steward AI is closed. Choose Always for Steward AI in iOS Settings to keep it going."
        )
        XCTAssertNil(LocationAlwaysAsk.closedAppNote(sharing: sharing, isAlways: true, at: clock))
        XCTAssertNil(LocationAlwaysAsk.closedAppNote(sharing: paused, isAlways: false, at: clock))
        XCTAssertNil(LocationAlwaysAsk.closedAppNote(sharing: nil, isAlways: false, at: clock))
    }

    // MARK: - The choice

    func testEachSpanEndsWhenItSays() {
        let hour = LocationSharing(audience: .assistant, span: .hour, from: clock, calendar: Self.indianapolis)
        let tonight = LocationSharing(audience: .assistant, span: .tonight, from: clock, calendar: Self.indianapolis)
        let always = LocationSharing(audience: .family, span: .always, from: clock, calendar: Self.indianapolis)

        XCTAssertEqual(hour.until, clock + 3600)
        XCTAssertEqual(tonight.until, Date(timeIntervalSince1970: 1_792_123_200), "midnight in Indianapolis")
        XCTAssertNil(always.until)
        XCTAssertFalse(hour.isPaused)
        XCTAssertEqual(tonight.endWords, "until midnight")
        XCTAssertEqual(always.endWords, "until you stop it")
        XCTAssertTrue(hour.endWords.hasPrefix("until "))
    }

    func testItSendsOnlyWhileItIsOnNotPausedAndNotOver() {
        var hour = LocationSharing(audience: .family, span: .hour, from: clock, calendar: Self.indianapolis)
        XCTAssertTrue(hour.isSending(at: clock))
        XCTAssertTrue(hour.isOver(at: clock + 3600))
        XCTAssertFalse(hour.isSending(at: clock + 3600))

        hour.isPaused = true
        XCTAssertFalse(hour.isSending(at: clock))
        XCTAssertFalse(hour.isOver(at: clock))

        let always = LocationSharing(audience: .assistant, span: .always, from: clock, calendar: Self.indianapolis)
        XCTAssertTrue(always.isSending(at: clock + 365 * 86_400))
    }

    // MARK: - When a position is news

    func testOnlyAPositionWorthSayingIsSent() {
        let last = fix(secondsAgo: 600)
        let cases: [(String, LocationFix, LocationFix?, Bool)] = [
            ("the first position", fix(), nil, true),
            ("a position iOS could not measure", fix(accuracy: -1), nil, false),
            ("a position wider than a city", fix(accuracy: 150_000), nil, false),
            ("an older position than the last", fix(secondsAgo: 700), last, false),
            ("the same position again", last, last, false),
            ("a short walk", fix(39.768853, secondsAgo: 300), last, false),
            ("a move inside its own accuracy", fix(39.772903, accuracy: 3000, secondsAgo: 300), last, false),
            ("a move of a few streets", fix(39.772003, secondsAgo: 300), last, true),
            ("a long move a moment after the last", fix(39.786403, secondsAgo: 570), last, false),
            ("an arrival a moment after the last", fix(39.768853, secondsAgo: 570, isVisit: true), last, true),
            ("an unmoved position ten minutes on", fix(secondsAgo: 0), last, false),
            ("an unmoved position a quarter of an hour on", fix(secondsAgo: 0), fix(secondsAgo: 900), true),
        ]
        for (label, next, previous, isSent) in cases {
            XCTAssertEqual(LocationSendRule.shouldSend(next, after: previous), isSent, label)
        }
    }

    // MARK: - Telling the gateway

    func testNothingIsSentUntilThePersonTurnsItOn() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)

        await sharing.consider(fix())
        await sharing.catchUp()

        XCTAssertNil(sharing.sharing)
        XCTAssertFalse(sharing.isSending)
        XCTAssertTrue(gateway.reports.isEmpty)
        XCTAssertTrue(gateway.signed.isEmpty)
    }

    func testTurningItOnSendsWhereThePhoneIsSignedForItsOwnAssistant() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)

        await sharing.start(with: .assistant, for: .hour)
        XCTAssertTrue(gateway.reports.isEmpty, "nothing until iOS has measured where the phone is")
        await sharing.consider(fix())

        XCTAssertEqual(gateway.signed, ["household-app/location/v1\n1792101119000\nassistant\n1792104719000\n1792101060000\n39768403\n-86158068\n65"])
        XCTAssertEqual(gateway.reports, [.object([
            "at": .number(1_792_101_119_000),
            "sharing": .string("assistant"),
            "until": .number(1_792_104_719_000),
            "position": .object([
                "latitudeE6": .number(39_768_403),
                "longitudeE6": .number(-86_158_068),
                "accuracy": .number(65),
                "at": .number(1_792_101_060_000),
            ]),
            "signature": .string("phone-signature-1"),
        ])])
        XCTAssertEqual(store.locationSharing?.audience, .assistant)
        XCTAssertEqual(store.locationSharing?.span, .hour)
        XCTAssertTrue(store.isLocationHeldByGateway)
        XCTAssertNil(sharing.errorText)
    }

    func testOnlyNewsIsSentWhileSharing() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let sharing = sharer(gateway, Store())
        await sharing.start(with: .assistant, for: .always)
        await sharing.consider(fix())

        clock += 30
        await sharing.consider(fix(39.768853, secondsAgo: 1))
        clock += 300
        await sharing.consider(fix(39.775403, secondsAgo: 1))

        XCTAssertEqual(gateway.reports.count, 2, "the short walk is not news, the move of a few streets is")
        XCTAssertEqual(gateway.reports.last?["position"]?["latitudeE6"], .number(39_775_403))
    }

    func testPausingTellsTheGatewayToForgetAndSendsNothingUntilItResumes() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)
        await sharing.start(with: .family, for: .always)
        await sharing.consider(fix())

        clock += 60
        await sharing.pause()

        XCTAssertEqual(gateway.signed.last, "household-app/location/v1\n1792101179000\noff\n\n\n\n\n")
        XCTAssertEqual(gateway.reports.last, .object(Self.stopped.merging(["at": .number(1_792_101_179_000), "signature": .string("phone-signature-2")]) { $1 }))
        XCTAssertEqual(store.locationSharing?.isPaused, true)
        XCTAssertFalse(store.isLocationHeldByGateway)
        XCTAssertFalse(sharing.isSending)

        clock += 600
        await sharing.consider(fix(39.80, secondsAgo: 1))
        await sharing.catchUp()
        XCTAssertEqual(gateway.reports.count, 2, "nothing while paused")

        clock += 60
        await sharing.resume()

        XCTAssertEqual(gateway.reports.count, 3)
        XCTAssertEqual(gateway.reports.last?["sharing"], .string("family"))
        XCTAssertEqual(gateway.reports.last?["until"], .null)
        XCTAssertEqual(gateway.reports.last?["position"]?["latitudeE6"], .number(39_800_000))
        XCTAssertTrue(store.isLocationHeldByGateway)
    }

    func testStoppingTurnsItOffAndTellsTheGatewayToForget() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)
        await sharing.start(with: .assistant, for: .tonight)
        await sharing.consider(fix())

        clock += 60
        await sharing.stop()
        clock += 600
        await sharing.consider(fix(39.80, secondsAgo: 1))

        XCTAssertEqual(gateway.reports.count, 2)
        XCTAssertEqual(gateway.reports.last?["sharing"], .string("off"))
        XCTAssertNil(store.locationSharing)
        XCTAssertFalse(store.isLocationHeldByGateway)
    }

    func testSharingEndsByItselfWhenItsTimeIsUp() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)
        await sharing.start(with: .assistant, for: .hour)
        await sharing.consider(fix())

        clock += 3600
        await sharing.consider(fix(39.80, secondsAgo: 1))

        XCTAssertEqual(gateway.reports.count, 2)
        XCTAssertEqual(gateway.reports.last?["sharing"], .string("off"), "a stop, and no position")
        XCTAssertNil(store.locationSharing)

        await sharing.start(with: .assistant, for: .hour)
        await sharing.consider(fix(39.80, secondsAgo: 1))
        clock += 3600
        await sharing.endIfOver()

        XCTAssertEqual(gateway.reports.count, 4)
        XCTAssertEqual(gateway.reports.last?["sharing"], .string("off"))
        XCTAssertNil(sharing.sharing)
    }

    func testSharingWithTheFamilyTooSendsTheLatestPositionAgain() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)
        await sharing.start(with: .assistant, for: .hour)
        await sharing.consider(fix())

        clock += 30
        await sharing.share(with: .family)

        XCTAssertEqual(gateway.reports.count, 2)
        XCTAssertEqual(gateway.reports.last?["sharing"], .string("family"))
        XCTAssertEqual(gateway.reports.last?["until"], .number(1_792_104_719_000), "the clock does not start again")
        XCTAssertEqual(gateway.reports.last?["position"], gateway.reports.first?["position"])
        XCTAssertEqual(store.locationSharing?.audience, .family)
    }

    func testChoosingHowLongStartsTheClockAgain() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)
        await sharing.start(with: .assistant, for: .hour)
        await sharing.consider(fix())

        clock += 600
        await sharing.share(for: .tonight)

        XCTAssertEqual(store.locationSharing?.span, .tonight)
        XCTAssertEqual(store.locationSharing?.until, Date(timeIntervalSince1970: 1_792_123_200))
        XCTAssertEqual(gateway.reports.last?["until"], .number(1_792_123_200_000))
    }

    func testWhatDidNotReachTheGatewayIsSentOnceTheLinkIsBack() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)
        await sharing.start(with: .assistant, for: .always)

        gateway.isRefusing = true
        await sharing.consider(fix())
        XCTAssertEqual(sharing.errorText, "the household app could not do that")
        XCTAssertTrue(store.isLocationHeldByGateway, "it may have arrived, so a stop is owed until one does")

        gateway.isRefusing = false
        clock += 5
        await sharing.catchUp()
        XCTAssertEqual(gateway.reports.count, 2)
        XCTAssertEqual(gateway.reports.last?["sharing"], .string("assistant"))
        XCTAssertNil(sharing.errorText)
        await sharing.catchUp()
        XCTAssertEqual(gateway.reports.count, 2, "the gateway has it")

        gateway.isRefusing = true
        clock += 60
        await sharing.stop()
        XCTAssertNil(store.locationSharing)
        XCTAssertTrue(store.isLocationHeldByGateway)

        gateway.isRefusing = false
        clock += 60
        await sharing.catchUp()
        XCTAssertEqual(gateway.reports.last?["sharing"], .string("off"))
        XCTAssertFalse(store.isLocationHeldByGateway)
    }

    func testSettingsSaysTheAssistantStillHasWhereYouWereUntilTheStopGetsThrough() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let sharing = sharer(gateway, Store())
        await sharing.start(with: .assistant, for: .always)
        await sharing.consider(fix())
        func state() -> LocationState {
            LocationState(permission: .allowed, sharing: sharing.sharing, isHeldByGateway: sharing.isHeldByGateway)
        }
        XCTAssertEqual(state().label, "Sharing")

        gateway.isRefusing = true
        await sharing.stop()
        XCTAssertEqual(state(), .off(isStillHeld: true))
        XCTAssertEqual(state().sentence(assistant: "Corey"), "Off. Corey forgets where you were once this iPhone gets through.")

        gateway.isRefusing = false
        await sharing.catchUp()
        XCTAssertEqual(state(), .off(isStillHeld: false))
        XCTAssertEqual(state().sentence(assistant: "Corey"), "Off. Corey does not know where you are.")
    }

    func testPairingAgainCarriesNothingOverToTheNextGateway() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)
        await sharing.start(with: .family, for: .always)
        await sharing.consider(fix())

        sharing.reset()
        XCTAssertNil(store.locationSharing)
        XCTAssertFalse(store.isLocationHeldByGateway)

        clock += 60
        await sharing.start(with: .assistant, for: .hour)
        await sharing.catchUp()
        XCTAssertEqual(gateway.reports.count, 1, "the position measured before is not handed on")
    }

    // MARK: - Precise or approximate

    func testAnApproximatePositionIsTheMiddleOfItsNeighbourhood() {
        let exact = fix()
        let approximate = exact.approximated

        XCTAssertEqual(approximate.position, LocationReport.Position(latitudeE6: 39_776_940, longitudeE6: -86_159_295, accuracy: 2_000, at: 1_792_101_060_000))
        XCTAssertLessThan(exact.distance(to: approximate), 1_415, "never further than the corner of its square")
        XCTAssertEqual(fix(39.775403, secondsAgo: 59).approximated.position, approximate.position, "a few streets on is the same neighbourhood")
        XCTAssertNotEqual(fix(39.762, -86.150).approximated.position.latitudeE6, approximate.position.latitudeE6)
        XCTAssertEqual(fix(accuracy: 3_500).approximated.accuracy, 3_500, "a vaguer position stays as vague")
        XCTAssertEqual(fix(accuracy: -1).approximated.accuracy, -1, "a position iOS could not measure stays one")
        XCTAssertTrue(fix(isVisit: true).approximated.isVisit)
    }

    func testWithPreciseOffOnlyTheNeighbourhoodIsSent() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        store.isLocationPrecise = false
        let sharing = sharer(gateway, store)
        await sharing.start(with: .assistant, for: .always)

        await sharing.consider(fix())
        clock += 300
        await sharing.consider(fix(39.775403, secondsAgo: 1))

        XCTAssertEqual(gateway.reports.count, 1, "a few streets on is still the same neighbourhood, so no news")
        XCTAssertEqual(gateway.reports.first?["position"], .object([
            "latitudeE6": .number(39_776_940),
            "longitudeE6": .number(-86_159_295),
            "accuracy": .number(2_000),
            "at": .number(1_792_101_060_000),
        ]))
        XCTAssertTrue(gateway.signed.allSatisfy { !$0.contains("39768403") }, "the exact position is never signed or sent")
    }

    func testTurningPreciseOnSendsTheExactPositionAtOnceAndOffSendsTheNeighbourhood() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        store.isLocationPrecise = false
        let sharing = sharer(gateway, store)
        await sharing.start(with: .assistant, for: .hour)
        await sharing.consider(fix())

        clock += 30
        await sharing.share(precisely: true)
        XCTAssertTrue(store.isLocationPrecise)
        XCTAssertEqual(gateway.reports.count, 2)
        XCTAssertEqual(gateway.reports.last?["position"]?["latitudeE6"], .number(39_768_403))

        clock += 30
        await sharing.share(precisely: false)
        XCTAssertFalse(store.isLocationPrecise)
        XCTAssertEqual(gateway.reports.count, 3)
        XCTAssertEqual(gateway.reports.last?["position"]?["latitudeE6"], .number(39_776_940))
    }

    func testPreciseIsAChoiceKeptWhileSharingIsOff() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharing = sharer(gateway, store)

        await sharing.share(precisely: false)

        XCTAssertFalse(store.isLocationPrecise)
        XCTAssertTrue(gateway.reports.isEmpty)
    }

    func testPreciseLocationSaysPlainlyWhatTheAssistantGets() {
        let cases: [(isWanted: Bool, isPreciseInIOS: Bool, isAllowed: Bool, LocationPrecision)] = [
            (true, true, true, .precise),
            (false, true, true, .approximate),
            (false, false, true, .approximate),
            (true, false, true, .keptApproximate),
            // Before iOS has been asked it has kept nothing approximate yet.
            (true, false, false, .precise),
        ]
        for (isWanted, isPreciseInIOS, isAllowed, expected) in cases {
            XCTAssertEqual(LocationPrecision(isWanted: isWanted, isPreciseInIOS: isPreciseInIOS, isAllowed: isAllowed), expected, "\(expected)")
        }
        XCTAssertEqual(LocationPrecision.precise.words(assistant: "Corey"), "Corey gets where you are to within a few metres.")
        XCTAssertEqual(LocationPrecision.approximate.words(assistant: "Corey"), "Off sends only the neighbourhood.")
        XCTAssertEqual(
            LocationPrecision.keptApproximate.words(assistant: "Corey"),
            "iOS keeps your location approximate, so Corey gets only the neighbourhood. Turn on Precise Location for Steward AI in iOS Settings to change that."
        )
    }

    func testAPhoneThatSharedBeforeItWasLastClosedPicksUpWhereItWas() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        store.locationSharing = LocationSharing(audience: .family, span: .hour, from: clock - 1800, calendar: Self.indianapolis)
        let sharing = sharer(gateway, store)

        XCTAssertTrue(sharing.isSending)
        await sharing.consider(fix())

        XCTAssertEqual(gateway.reports.first?["sharing"], .string("family"))
        XCTAssertEqual(gateway.reports.first?["until"], .number(1_792_102_919_000))
    }
}
