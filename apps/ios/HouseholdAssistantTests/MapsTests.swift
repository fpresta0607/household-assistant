// Maps: a map shared in a conversation, once or live, signed as the gateway checks it,
// moved while it lasts and over when its time is up; the assistant's map and
// place-reminder cards; and what a reminder by place shows on this phone, its own or one
// that asks for this person's yes.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class MapsTests: XCTestCase {
    /// A connected gateway that keeps every live update, or refuses them while told to.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var refusal: String?
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
                } else if request.method == "household-app.history" {
                    transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"messages":[],"hasMore":false,"reactions":{},"reads":[],"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{}}}"#)
                } else if request.method == "household-app.sync" {
                    transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"entries":[],"rev":0,"hasMore":false,"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{}}}"#)
                } else if request.method == "household-app.send", let id = request.params["id"]?.stringValue {
                    let location = request.params["location"].map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? "null"
                    transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"entry":{"id":"\#(id)","rev":7,"kind":"message","conversation":"family","author":"franco","at":\#(request.params["at"]?.intValue ?? 0),"origin":"local","text":"","media":[],"replyTo":null,"location":\#(location)}}}"#)
                } else if let refusal = self?.refusal {
                    transport.push(#"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"\#(refusal)"}}"#)
                } else {
                    transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"entry":{}}}"#)
                }
            }
        }

        func sign(_ text: String) -> String {
            signed.append(text)
            return "phone-signature-\(signed.count)"
        }

        var updates: [JSONValue] {
            transport.requests.filter { $0.method == "household-app.location.live" }.map(\.params)
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
    private final class Store: LiveShareStore, PlaceWatchStore {
        var liveShares: [LiveShare] = []
        var isLocationPrecise = true
        var placeWatches: [PlaceWatch] = []
        var firedPlaceWatches: [String] = []
    }

    /// 5:51:59 PM in Indianapolis on 15 October 2026.
    private var clock = Date(timeIntervalSince1970: 1_792_101_119)

    private static let indianapolis: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        return calendar
    }()

    /// Leo on Maple Street, `secondsAgo` before the clock, `north` metres further on.
    private func fix(north metres: Double = 0, accuracy: Double = 12, secondsAgo: TimeInterval = 0) -> LocationFix {
        LocationFix(latitude: 39.768403 + metres / 111_195, longitude: -86.158068, accuracy: accuracy, at: clock - secondsAgo)
    }

    private func sharer(_ gateway: Gateway, _ store: Store) -> LiveShareModel {
        LiveShareModel(connection: gateway.connection, sign: gateway.sign, store: store, now: { self.clock })
    }

    private func block(_ json: String) -> String {
        "```steward-card\n\(json)\n```"
    }

    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> CardContent {
        let found = StewardCardParser.segments(in: block(json), isStreaming: false)
        guard case .card(let card)? = found.first, found.count == 1 else {
            XCTFail("not one card: \(found)", file: file, line: line)
            throw CocoaError(.coderReadCorrupt)
        }
        return card.content
    }

    private func isCode(_ json: String) -> Bool {
        if case .code? = StewardCardParser.segments(in: block(json), isStreaming: false).first {
            return true
        }
        return false
    }

    // MARK: - What the phone signs

    func testAMapIsSignedWithItsPlaceAndEndAsTheGatewayChecksIt() {
        let live = SharedLocation(
            position: LocationReport.Position(latitudeE6: 39_768_403, longitudeE6: -86_158_068, accuracy: 12, at: 1_792_101_114_000),
            until: 1_792_104_719_000
        )
        let once = SharedLocation(position: live.position, until: nil)

        XCTAssertEqual(
            RoomSignature.signedText(conversation: .family, id: "m-1", at: 1_792_101_119_000, replyTo: nil, mediaIds: [], location: live, text: ""),
            "household-app/map/v1\nfamily\nm-1\n1792101119000\n\n1792104719000\n39768403\n-86158068\n12\n1792101114000\n"
        )
        XCTAssertEqual(
            RoomSignature.signedText(conversation: .direct, id: "d-1", at: 5, replyTo: "a-2", mediaIds: [], location: once, text: "Here"),
            "household-app/map/v1\ndirect\nd-1\n5\na-2\n\n39768403\n-86158068\n12\n1792101114000\nHere"
        )
        XCTAssertEqual(
            RoomSignature.signedText(conversation: .family, id: "m-2", at: 5, replyTo: nil, mediaIds: [], text: "Plain"),
            "household-app/v1\nfamily\nm-2\n5\n\n\nPlain",
            "a message with no place signs as it always did"
        )
    }

    func testAMoveAStopAndAnAnswerAreSignedAsTheGatewayChecksThem() {
        let move = LiveLocationUpdate(
            messageId: "m-1",
            at: 1_792_101_179_000,
            position: LocationReport.Position(latitudeE6: 39_771_950, longitudeE6: -86_151_210, accuracy: 9, at: 1_792_101_178_000)
        )

        XCTAssertEqual(move.signedText, "household-app/live/v1\nm-1\n1792101179000\n1792101178000\n39771950\n-86151210\n9")
        XCTAssertEqual(LiveLocationUpdate(messageId: "m-1", at: 7, position: nil).signedText, "household-app/live/v1\nm-1\n7\n\n\n\n")
        XCTAssertNil(LiveLocationUpdate(messageId: "m-1\nm-2", at: 7, position: nil).signedText)
        XCTAssertEqual(PlaceAnswer.signedText(messageId: "a-9", answer: .yes, at: 1_792_101_119_000), "household-app/place/v1\na-9\nyes\n1792101119000")
        XCTAssertNil(PlaceAnswer.signedText(messageId: "a-9\r", answer: .no, at: 1))
    }

    // MARK: - What the gateway says

    func testAThreadShowsAMapWithItsNewestMoveAndEachAnswer() async throws {
        let decoder = JSONDecoder()
        let map = try decoder.decode(RoomEntry.self, from: Data(#"{"id":"m-1","rev":1,"kind":"message","conversation":"family","author":"gia","at":1792101119000,"origin":"peer","text":"","media":[],"replyTo":null,"location":{"latitudeE6":39768403,"longitudeE6":-86158068,"accuracy":12,"at":1792101114000,"until":1792104719000}}"#.utf8))
        let newer = try decoder.decode(RoomEntry.self, from: Data(#"{"id":"live:m-1","rev":3,"kind":"live","conversation":"family","author":"gia","at":1792101239000,"origin":"peer","messageId":"m-1","position":{"latitudeE6":39771950,"longitudeE6":-86151210,"accuracy":9,"at":1792101238000}}"#.utf8))
        let older = try decoder.decode(RoomEntry.self, from: Data(#"{"id":"live:m-1","rev":2,"kind":"live","conversation":"family","author":"gia","at":1792101179000,"origin":"peer","messageId":"m-1","position":{"latitudeE6":39768500,"longitudeE6":-86158000,"accuracy":9,"at":1792101178000}}"#.utf8))
        let stop = try decoder.decode(RoomEntry.self, from: Data(#"{"id":"live:m-1","rev":4,"kind":"live","conversation":"family","author":"gia","at":1792101299000,"origin":"peer","messageId":"m-1","position":null}"#.utf8))
        let answer = try decoder.decode(RoomEntry.self, from: Data(#"{"id":"place:a-9:gia","rev":5,"kind":"place","conversation":"family","author":"gia","at":1792101299000,"origin":"peer","messageId":"a-9","answer":"yes"}"#.utf8))
        var thread = RoomThread(.family)

        thread.apply(map)
        XCTAssertEqual(thread.messages.first?.location?.until, 1_792_104_719_000)
        XCTAssertEqual(thread.messages.first?.location?.latitude ?? 0, 39.768403, accuracy: 0.000001)
        thread.apply(newer)
        thread.apply(older)
        XCTAssertEqual(thread.messages.first?.live?.position?.latitudeE6, 39_771_950, "an older move never replaces a newer one")
        thread.apply(stop)
        XCTAssertEqual(thread.messages.first?.live, RoomLive(at: 1_792_101_299_000, position: nil))
        thread.apply(answer)
        XCTAssertEqual(thread.placeAnswers["a-9"], ["gia": .yes])
    }

    func testAPageCarriesEachLiveMapsNewestMoveAndEachAnswer() async throws {
        let page = try JSONDecoder().decode(RoomHistoryPage.self, from: Data(#"""
        {"messages":[{"id":"m-1","rev":1,"kind":"message","conversation":"family","author":"franco","at":1792101119000,"origin":"local","text":"","media":[],"replyTo":null,"location":{"latitudeE6":39768403,"longitudeE6":-86158068,"accuracy":12,"at":1792101114000,"until":null}}],
         "hasMore":false,"reactions":{},"reads":[],"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{},
         "lives":{"m-1":{"at":1792101239000,"position":{"latitudeE6":39771950,"longitudeE6":-86151210,"accuracy":9,"at":1792101238000}}},
         "places":{"a-9":[{"author":"franco","answer":"no"}]}}
        """#.utf8))
        var thread = RoomThread(.family)

        thread.load(page)

        XCTAssertNil(thread.messages.first?.location?.until)
        XCTAssertEqual(thread.messages.first?.live?.at, 1_792_101_239_000)
        XCTAssertEqual(thread.placeAnswers["a-9"], ["franco": .no])
    }

    func testSharingAMapSendsItsPlaceSignedAndShowsItAtOnce() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let room = RoomModel(connection: gateway.connection, sign: gateway.sign, now: { self.clock }, makeId: { "map-0001" })
        await room.refresh()
        let location = SharedLocation(position: fix().position, until: 1_792_102_019_000)

        let kept = await room.share(location, in: .family)

        XCTAssertEqual(kept?.id, "m-map-0001")
        XCTAssertEqual(kept?.at, 1_792_101_119_000)
        XCTAssertEqual(room.family.messages.last?.location, location)
        XCTAssertEqual(room.family.messages.last?.rev, 7)
        let sent = try XCTUnwrap(gateway.transport.requests.first { $0.method == "household-app.send" }?.params)
        XCTAssertEqual(sent["location"]?["until"]?.intValue, 1_792_102_019_000)
        XCTAssertEqual(gateway.signed.first, "household-app/map/v1\nfamily\nm-map-0001\n1792101119000\n\n1792102019000\n39768403\n-86158068\n12\n1792101119000\n")
    }

    func testAnAnswerToAPlaceCardShowsAtOnceAndARefusedOneIsTakenBack() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let room = RoomModel(connection: gateway.connection, sign: gateway.sign, now: { self.clock })
        await room.refresh()

        let isTaken = await room.answerPlace("a-9", with: .yes)
        gateway.refusal = "no reminder by place there asks for you"
        let isRefused = await room.answerPlace("a-9", with: .no)

        XCTAssertTrue(isTaken)
        XCTAssertFalse(isRefused)
        XCTAssertEqual(room.family.placeAnswers["a-9"], ["franco": .yes])
        XCTAssertEqual(room.placeRefusals["a-9"], "no reminder by place there asks for you")
        XCTAssertEqual(gateway.signed.first, "household-app/place/v1\na-9\nyes\n1792101119000")
    }

    func testAWidgetSaysAMapIsOneAndNeverWhere() async throws {
        let map = try JSONDecoder().decode(RoomEntry.self, from: Data(#"{"id":"m-1","rev":1,"kind":"message","conversation":"family","author":"gia","at":1792101119000,"origin":"peer","text":"","media":[],"replyTo":null,"location":{"latitudeE6":39768403,"longitudeE6":-86158068,"accuracy":12,"at":1792101114000,"until":1792104719000}}"#.utf8))
        var family = RoomThread(.family)
        family.apply(map)
        var snapshot = WidgetSnapshot()

        snapshot.show(family: family, direct: RoomThread(.direct), participants: [], me: RoomSelf(person: "franco", assistant: "corey"))

        XCTAssertEqual(snapshot.family.lines.first?.text, "Live location")
        XCTAssertEqual(snapshot.family.lines.first?.symbol, "location.fill")
        XCTAssertEqual(
            MessagePlainText.text(of: block(#"{"type":"place-reminder","text":"Take the trash out","place":{"label":"home","latitude":1,"longitude":2},"when":"arrive"}"#), calendar: Self.indianapolis),
            "Reminder by place: Take the trash out\nOn arriving at home"
        )
    }

    // MARK: - How long a share lasts

    func testEachSpanEndsWhenItSays() {
        XCTAssertNil(MapShareSpan.once.until(from: clock, calendar: Self.indianapolis))
        XCTAssertEqual(MapShareSpan.quarterHour.until(from: clock, calendar: Self.indianapolis), clock + 15 * 60)
        XCTAssertEqual(MapShareSpan.hour.until(from: clock, calendar: Self.indianapolis), clock + 3600)
        XCTAssertEqual(MapShareSpan.endOfDay.until(from: clock, calendar: Self.indianapolis), Date(timeIntervalSince1970: 1_792_123_200), "midnight in Indianapolis")
        XCTAssertEqual(MapShareSpan.allCases.map(\.title), ["Once", "For 15 minutes", "For 1 hour", "Until the end of the day"])
    }

    func testALiveShareSendsSignedMovesUntilItEndsAndNothingAfter() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharer = sharer(gateway, store)
        sharer.start(LiveShare(messageId: "m-1", conversation: .family, until: clock + 15 * 60), at: fix(), sentAt: 1_792_101_119_000)

        clock += 60
        await sharer.consider(fix(north: 400))
        clock += 5
        await sharer.consider(fix(north: 800))
        clock += 30
        await sharer.consider(fix(north: 410))
        clock += 15 * 60
        await sharer.consider(fix(north: 2000))

        XCTAssertEqual(gateway.updates.count, 1, "too soon after the last, then too small a move, then over")
        XCTAssertEqual(gateway.updates.first?["messageId"]?.stringValue, "m-1")
        XCTAssertEqual(gateway.updates.first?["at"]?.intValue, 1_792_101_179_000)
        XCTAssertEqual(gateway.signed.first, "household-app/live/v1\nm-1\n1792101179000\n1792101179000\n39772000\n-86158068\n12")
        XCTAssertTrue(store.liveShares.isEmpty, "a share whose time is up is forgotten")
        XCTAssertFalse(sharer.isFollowing)
    }

    func testAMoveAfterAQuietWhileIsSentEvenIfSmall() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let sharer = sharer(gateway, Store())
        sharer.start(LiveShare(messageId: "m-1", conversation: .family, until: clock + 3600), at: fix(), sentAt: 1_792_101_119_000)

        clock += LiveShareRule.staleSeconds
        await sharer.consider(fix(north: 3))

        XCTAssertEqual(gateway.updates.count, 1)
        XCTAssertTrue(sharer.isFollowing)
    }

    func testStoppingSendsAStopAndForgetsTheShare() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharer = sharer(gateway, store)
        sharer.start(LiveShare(messageId: "m-1", conversation: .direct, until: clock + 3600), at: fix(), sentAt: 1_792_101_119_000)

        clock += 1
        let isStopped = await sharer.stop("m-1")

        XCTAssertTrue(isStopped)
        XCTAssertEqual(gateway.updates.first?["position"], .null)
        XCTAssertEqual(gateway.signed, ["household-app/live/v1\nm-1\n1792101120000\n\n\n\n"])
        XCTAssertTrue(store.liveShares.isEmpty)
        XCTAssertFalse(sharer.isSharing("m-1"))
    }

    func testAShareTheGatewayRefusesIsForgottenAndOneItCannotReachIsKept() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        let sharer = sharer(gateway, store)
        sharer.start(LiveShare(messageId: "m-1", conversation: .family, until: clock + 3600), at: fix(), sentAt: 1_792_101_119_000)
        gateway.refusal = "that share has stopped"

        clock += 60
        await sharer.consider(fix(north: 400))

        XCTAssertEqual(gateway.updates.count, 1)
        XCTAssertTrue(store.liveShares.isEmpty)
        XCTAssertEqual(sharer.errorText, "that share has stopped")
    }

    func testWithPreciseLocationOffOnlyTheNeighbourhoodMoves() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = Store()
        store.isLocationPrecise = false
        let sharer = sharer(gateway, store)
        sharer.start(LiveShare(messageId: "m-1", conversation: .family, until: clock + 3600), at: fix().approximated, sentAt: 1_792_101_119_000)

        clock += 60
        await sharer.consider(fix(north: 400))
        clock += 60
        await sharer.consider(fix(north: 5000))

        XCTAssertEqual(gateway.updates.count, 1, "a move within the same neighbourhood is no move at all")
        let accuracy = gateway.updates.first?["position"]?["accuracy"]?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(accuracy, Int(LocationFix.neighbourhoodMetres))
    }

    // MARK: - The assistant's map

    func testAMapCardReadsItsPlaceItsPinAndTheWayThere() async throws {
        let home = try card(#"{"type":"map","center":{"latitude":39.7684,"longitude":-86.1581},"label":"Home","route":"driving"}"#)
        let plain = try card(#"{"type":"map","center":{"latitude":-33.8568,"longitude":151.2153}}"#)

        XCTAssertEqual(home, .map(MapCard(center: MapPoint(latitude: 39.7684, longitude: -86.1581), label: "Home", route: .driving)))
        XCTAssertEqual(plain, .map(MapCard(center: MapPoint(latitude: -33.8568, longitude: 151.2153), label: nil, route: nil)))
        XCTAssertTrue(isCode(#"{"type":"map","center":{"latitude":91,"longitude":0}}"#), "no place is off the earth")
        XCTAssertTrue(isCode(#"{"type":"map","center":{"latitude":1,"longitude":2},"route":"flying"}"#))
        XCTAssertTrue(isCode(#"{"type":"map","label":"Home"}"#))
    }

    func testTheWayThereSaysHowLongAndWhenTheyArrive() {
        let route = MapRoute(points: [], seconds: 18 * 60 + 20, metres: 14_200, name: "Maple Street")

        XCTAssertEqual(route.minutes, 18)
        XCTAssertEqual(route.arrival(leaving: clock), clock + 18 * 60 + 20)
        XCTAssertEqual(MapRoute(points: [], seconds: 20, metres: 90, name: "").minutes, 1, "under a minute still reads as a minute")
        XCTAssertEqual(
            MapCard(center: MapPoint(latitude: 39.7684, longitude: -86.1581), label: "Home", route: .driving).routeKey(in: "a-1"),
            "a-1|39.7684,-86.1581|driving"
        )
    }

    // MARK: - Reminders by place

    func testAPlaceReminderCardReadsWhatWhenAndWhere() async throws {
        let trash = try card(#"{"type":"place-reminder","text":"Take the trash out","place":{"label":"home","latitude":39.7684,"longitude":-86.1581},"when":"arrive"}"#)
        let work = try card(#"{"type":"place-reminder","text":"Tell Leo","place":{"label":"work","latitude":39.7817,"longitude":-86.1478,"radius":200},"when":"leave","for":"Rosa"}"#)

        XCTAssertEqual(trash, .placeReminder(PlaceReminderCard(
            text: "Take the trash out",
            place: PlaceReminderCard.Place(label: "home", center: MapPoint(latitude: 39.7684, longitude: -86.1581), radius: 150),
            when: .arrive,
            for: nil
        )))
        guard case .placeReminder(let leaving) = work else {
            return XCTFail("not a place reminder")
        }
        XCTAssertEqual(leaving.place.radius, 200)
        XCTAssertEqual(leaving.for, "Rosa")
        XCTAssertTrue(isCode(#"{"type":"place-reminder","text":"x","place":{"label":"home","latitude":1,"longitude":2,"radius":20},"when":"arrive"}"#), "too small to watch")
        XCTAssertTrue(isCode(#"{"type":"place-reminder","text":"x","place":{"label":"home","latitude":1,"longitude":2},"when":"pass"}"#))
        XCTAssertTrue(isCode(#"{"type":"place-reminder","text":" ","place":{"label":"home","latitude":1,"longitude":2},"when":"arrive"}"#))
        XCTAssertTrue(isCode(#"{"type":"place-reminder","text":"x","place":{"label":"","latitude":1,"longitude":2},"when":"arrive"}"#))
    }

    private static let participants = [
        RoomParticipant(id: "franco", name: "Leo", kind: .person, isOwner: true),
        RoomParticipant(id: "gia", name: "Rosa", kind: .person, isOwner: false),
        RoomParticipant(id: "corey", name: "Corey", kind: .assistant, isOwner: false),
        RoomParticipant(id: "denise", name: "Denise", kind: .assistant, isOwner: false),
    ]

    private func state(
        for person: String?,
        by author: String,
        answers: [String: PlaceAnswer] = [:],
        isWatching: Bool = false,
        hasFired: Bool = false
    ) -> PlaceReminderState {
        PlaceReminderState(
            card: PlaceReminderCard(
                text: "Tell them",
                place: PlaceReminderCard.Place(label: "work", center: MapPoint(latitude: 1, longitude: 2), radius: 150),
                when: .leave,
                for: person
            ),
            author: author,
            me: RoomSelf(person: "franco", assistant: "corey"),
            participants: Self.participants,
            answers: answers,
            isWatching: isWatching,
            hasFired: hasFired
        )
    }

    func testAReminderByPlaceShowsWhatThisPhoneMayDoWithIt() {
        // Leo's own, from Corey: set it, watched, gone off.
        XCTAssertEqual(state(for: nil, by: "corey"), .readyToSet)
        XCTAssertEqual(state(for: "franco", by: "corey", isWatching: true), .watching)
        XCTAssertEqual(state(for: "Leo", by: "corey", hasFired: true), .done)
        // Denise asking to watch Leo: his yes or no, on his own phone only.
        XCTAssertEqual(state(for: "Leo", by: "denise"), .askingYou(asker: "Denise"))
        XCTAssertEqual(state(for: "franco", by: "denise", answers: ["franco": .yes]), .youSaidYes(asker: "Denise"))
        XCTAssertEqual(state(for: "FRANCO", by: "denise", answers: ["franco": .no, "gia": .yes]), .youSaidNo(asker: "Denise"))
        // Corey asking to watch Rosa: her answer, as her phone gave it.
        XCTAssertEqual(state(for: "Rosa", by: "corey"), .waitingFor("Rosa"))
        XCTAssertEqual(state(for: "gia", by: "corey", answers: ["gia": .yes]), .theySaidYes("Rosa"))
        XCTAssertEqual(state(for: "Rosa", by: "corey", answers: ["gia": .no, "franco": .yes]), .theySaidNo("Rosa"))
        // Denise's reminder for Rosa herself, and one for somebody nobody knows: only shown.
        XCTAssertEqual(state(for: nil, by: "denise"), .theirs("Rosa"))
        XCTAssertEqual(state(for: "Mom", by: "corey"), .theirs("Mom"))
    }

    func testSettingAReminderWatchesItUntilItGoesOffOnce() {
        let store = Store()
        let reminders = PlaceReminders(store: store)
        let trash = PlaceWatch(
            id: "a-1",
            text: "Take the trash out",
            label: "home",
            center: MapPoint(latitude: 39.7684, longitude: -86.1581),
            radius: 150,
            when: .arrive,
            repliesInRoom: false
        )

        reminders.watch(trash)
        reminders.watch(trash)

        XCTAssertEqual(store.placeWatches, [trash])
        XCTAssertTrue(reminders.isWatching("a-1"))
        XCTAssertEqual(reminders.fired("a-1"), trash)
        XCTAssertNil(reminders.fired("a-1"), "it goes off once")
        XCTAssertTrue(reminders.hasFired("a-1"))
        XCTAssertFalse(reminders.isWatching("a-1"))
        XCTAssertEqual(store.firedPlaceWatches, ["a-1"])
    }

    func testItGoesOffOnlyWhenThePersonCrossesTheEdgeTheWayItSays() {
        let store = Store()
        let reminders = PlaceReminders(store: store)
        let home = PlaceWatch(id: "a-1", text: "Take the trash out", label: "home", center: MapPoint(latitude: 1, longitude: 2), radius: 150, when: .arrive, repliesInRoom: false)
        let work = PlaceWatch(id: "a-2", text: "Tell Leo", label: "work", center: MapPoint(latitude: 1, longitude: 2), radius: 200, when: .leave, repliesInRoom: true)
        reminders.watch(home)
        reminders.watch(work)

        XCTAssertNil(reminders.saw("a-1", isInside: true), "already home when it was set")
        XCTAssertNil(reminders.saw("a-1", isInside: false))
        XCTAssertEqual(reminders.saw("a-1", isInside: true)?.id, "a-1", "out, then home again")
        XCTAssertNil(reminders.saw("a-2", isInside: false), "not at work when it was set")
        XCTAssertNil(reminders.saw("a-2", isInside: true))
        XCTAssertEqual(reminders.saw("a-2", isInside: false)?.id, "a-2")
        XCTAssertNil(reminders.saw("a-3", isInside: true), "nothing watched by that id")
        XCTAssertTrue(store.placeWatches.isEmpty)
    }

    func testWhatAReminderSaysWhenItGoesOff() {
        let home = PlaceWatch(id: "a-1", text: "Take the trash out", label: "home", center: MapPoint(latitude: 1, longitude: 2), radius: 150, when: .arrive, repliesInRoom: false)
        let work = PlaceWatch(id: "a-2", text: "Tell Leo", label: "work", center: MapPoint(latitude: 1, longitude: 2), radius: 200, when: .leave, repliesInRoom: true)

        XCTAssertEqual(home.happened, "Arrived at home")
        XCTAssertEqual(work.happened, "Left work")
        XCTAssertEqual(work.reply, "Left work.")
    }

    /// CLMonitor stops the app on a name with anything but letters and digits, as the Mac
    /// preview of 9ba6081 showed with "steward-places".
    func testThePlaceMonitorIsNamedWithLettersAndDigitsOnly() {
        XCTAssertFalse(PlaceWatch.monitorName.isEmpty)
        XCTAssertTrue(PlaceWatch.monitorName.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        })
    }
}
