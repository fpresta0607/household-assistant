// The phone's half of the household-app channel, driven over a scripted gateway: what
// it asks for, what it signs, and what it shows while it waits.

import Observation
import XCTest
@testable import HouseholdAssistant

@MainActor
final class RoomModelTests: XCTestCase {
    /// A connected gateway that answers each household-app method from a closure.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var answers: [String: (GatewayRequest) -> String] = [:]
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
                } else if let answer = self?.answers[request.method] {
                    transport.push(answer(request))
                }
            }
        }

        func sign(_ text: String) -> String {
            signed.append(text)
            return "phone-signature-\(signed.count)"
        }

        func requests(_ method: String) -> [GatewayRequest] {
            transport.requests.filter { $0.method == method }
        }
    }

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

    private static let emptyHistory =
        #"{"messages":[],"hasMore":false,"reactions":{},"reads":[],"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{"family":"agent:main:household:group:family","direct":"agent:main:household:direct:franco"}}"#

    private static func syncPage(rev: Int, entries: String = "[]", hasMore: Bool = false) -> String {
        #"{"entries":\#(entries),"rev":\#(rev),"hasMore":\#(hasMore),"participants":[{"id":"franco","name":"Leo","kind":"person","isOwner":true},{"id":"gia","name":"Rosa","kind":"person","isOwner":false},{"id":"corey","name":"Corey","kind":"assistant","isOwner":false,"emoji":"🦉"},{"id":"denise","name":"Denise","kind":"assistant","isOwner":false}],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{"family":"agent:main:household:group:family","direct":"agent:main:household:direct:franco"}}"#
    }

    private static func messageEntry(_ id: String, rev: Int, author: String = "gia", conversation: String = "family", text: String = "hello", runId: String? = nil) -> String {
        let run = runId.map { #","runId":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","rev":\#(rev),"kind":"message","conversation":"\#(conversation)","author":"\#(author)","at":1792018800000,"origin":"peer","text":"\#(text)","media":[],"replyTo":null\#(run)}"#
    }

    private var clock = Date(timeIntervalSince1970: 1_792_018_900)
    private var ids = 0

    private func makeModel(_ gateway: Gateway, archive: RoomArchive? = nil) -> RoomModel {
        RoomModel(
            connection: gateway.connection,
            sign: { gateway.sign($0) },
            archive: archive,
            now: { [unowned self] in self.clock },
            makeId: { [unowned self] in
                self.ids += 1
                return "00000000-0000-4000-8000-\(String(format: "%012d", self.ids))"
            }
        )
    }

    private func connected(_ gateway: Gateway) async {
        gateway.connection.start(GatewayConnection.Configuration(
            url: URL(string: "ws://127.0.0.1:18800")!,
            client: .stewardPhone(displayName: "test", version: "0.1.0"),
            scopes: OperatorScope.chat,
            locale: "en-US"
        ))
        await eventually("connected") { gateway.connection.state == .connected }
    }

    private func eventually(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var attemptsLeft = 400
        while attemptsLeft > 0, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
    }

    private func standardAnswers(_ gateway: Gateway) {
        gateway.answers["household-app.history"] = { request in
            request.params["conversation"]?.stringValue == "family"
                ? Self.ok(request, Self.fixturePayload("household-app-history-response"))
                : Self.ok(request, Self.emptyHistory)
        }
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.fixturePayload("household-app-sync-response"))
        }
        gateway.answers["household-app.send"] = { request in
            let id = request.params["id"]?.stringValue ?? ""
            let conversation = request.params["conversation"]?.stringValue ?? ""
            return Self.ok(request, #"{"entry":\#(Self.messageEntry(id, rev: 50, author: "franco", conversation: conversation, text: request.params["text"]?.stringValue ?? ""))}"#)
        }
    }

    func testRefreshReadsTheNewestOfEachConversationThenCatchesUp() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)

        await room.refresh()

        XCTAssertEqual(gateway.requests("household-app.history").compactMap { $0.params["conversation"]?.stringValue }.sorted(), ["direct", "family"])
        XCTAssertEqual(room.thread(.family).messages.map(\.author), ["franco", "corey", "gia"])
        XCTAssertEqual(room.thread(.direct).messages.map(\.text), ["What is on my calendar tomorrow?"])
        XCTAssertEqual(room.rev, 6)
        XCTAssertEqual(room.me, RoomSelf(person: "franco", assistant: "corey"))
        XCTAssertEqual(room.participant("corey")?.emoji, "🦉")
        XCTAssertEqual(room.isAvailable, true)
    }

    // MARK: - Kept on the phone

    private func temporaryArchive() -> RoomArchive {
        RoomArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent("room-archive-" + UUID().uuidString))
    }

    /// Section 21: a thread opens from the phone, offline too, rather than waiting for its
    /// gateway. The family room comes from a page and Corey's thread from the changes after
    /// it, so both kinds of what is kept are read back.
    func testBothThreadsOpenFromThePhoneWithNoGatewayAtAll() async {
        // Arrange
        let archive = temporaryArchive()
        defer { archive.forget() }
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let online = makeModel(gateway, archive: archive)
        await online.refresh()
        await eventually("the archive is written") {
            archive.read(.family) != nil && archive.read(.direct).map { !$0.changes.isEmpty } == true
        }

        // Act
        let offline = makeModel(Gateway(), archive: archive)
        await offline.restore()

        // Assert
        XCTAssertEqual(offline.thread(.family).messages, online.thread(.family).messages)
        XCTAssertEqual(offline.thread(.direct).messages, online.thread(.direct).messages)
        XCTAssertEqual(offline.thread(.direct).messages.map(\.text), ["What is on my calendar tomorrow?"])
        XCTAssertEqual(offline.participants, online.participants)
        XCTAssertEqual(offline.me, online.me)
    }

    func testAPageFromTheGatewayIsNeverCoveredByWhatThePhoneKept() async throws {
        // Arrange
        let archive = temporaryArchive()
        defer { archive.forget() }
        let page = #"{"messages":[\#(Self.messageEntry("m-kept", rev: 1, text: "kept"))],"hasMore":false,"reactions":{},"reads":[],"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{}}"#
        archive.write(RoomArchive.Kept(page: try JSONDecoder().decode(JSONValue.self, from: Data(page.utf8))), for: .family)
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway, archive: archive)
        await room.refresh()

        // Act
        await room.restore()

        // Assert
        XCTAssertFalse(room.thread(.family).messages.contains { $0.id == "m-kept" })
        XCTAssertEqual(room.thread(.family).messages.map(\.author), ["franco", "corey", "gia"])
    }

    func testForgettingTheAssistantForgetsWhatThePhoneKept() async {
        // Arrange
        let archive = temporaryArchive()
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway, archive: archive)
        await room.refresh()
        await eventually("the archive is written") { archive.read(.family) != nil }

        // Act
        room.reset()

        // Assert: gone, and still gone once a write that was under way has ended, which put
        // a conversation back after it was forgotten when the forgetting did not wait for it.
        await eventually("the archive is forgotten") { archive.read(.family) == nil && archive.read(.direct) == nil }
        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertNil(archive.read(.family))
        XCTAssertNil(archive.read(.direct))
    }

    func testTheChangesKeptAfterAPageStopAtTheLimitDroppingTheOldest() {
        // Arrange
        let kept = RoomArchive.Kept(page: .null, changes: (0..<RoomArchive.mostChanges).map { .number(Double($0)) })

        // Act
        let added = kept.adding([.number(-1), .number(-2)])

        // Assert
        XCTAssertEqual(added.changes.count, RoomArchive.mostChanges)
        XCTAssertEqual(added.changes.first, .number(2))
        XCTAssertEqual(added.changes.suffix(2), [.number(-1), .number(-2)])
    }

    func testAFamilyMessageIsSignedShownAtOnceAndSettlesWhenKept() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        await room.send("Corey, add eggs", in: .family)

        let send = gateway.requests("household-app.send").last
        let id = "m-00000000-0000-4000-8000-000000000001"
        XCTAssertEqual(send?.params["id"]?.stringValue, id)
        XCTAssertEqual(send?.params["signature"]?.stringValue, "phone-signature-1")
        XCTAssertEqual(gateway.signed, ["household-app/v1\nfamily\n\(id)\n1792018900000\n\n\nCorey, add eggs"])
        XCTAssertEqual(room.thread(.family).messages.last?.id, id)
        XCTAssertEqual(room.thread(.family).messages.last?.status, .sent)
    }

    func testADirectMessageIsSignedToo() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        await room.send("What is on today?", in: .direct)

        let id = "d-00000000-0000-4000-8000-000000000001"
        XCTAssertEqual(gateway.requests("household-app.send").last?.params["id"]?.stringValue, id)
        XCTAssertEqual(gateway.requests("household-app.send").last?.params["signature"]?.stringValue, "phone-signature-1")
        XCTAssertEqual(gateway.signed, ["household-app/v1\ndirect\n\(id)\n1792018900000\n\n\nWhat is on today?"])
    }

    /// A call's words go to the thread as a message like any other, signed the same, and
    /// marked as said on a call, so the assistant answers them to be heard.
    func testWordsSaidOnACallAreSignedAsTypedWordsAreAndMarked() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        // Act
        await room.send("Is it cold inside?", in: .direct, isCall: true)
        await room.send("And tomorrow?", in: .direct)

        // Assert
        let sends = gateway.requests("household-app.send")
        XCTAssertEqual(sends.map { $0.params["call"] }, [.bool(true), nil])
        XCTAssertEqual(gateway.signed, [
            "household-app/v1\ndirect\nd-00000000-0000-4000-8000-000000000001\n1792018900000\n\n\nIs it cold inside?",
            "household-app/v1\ndirect\nd-00000000-0000-4000-8000-000000000002\n1792018900000\n\n\nAnd tomorrow?",
        ])
        XCTAssertEqual(room.thread(.direct).messages.suffix(2).map(\.status), [.sent, .sent])
    }

    func testAMessageSaidWithNoLinkWaitsInItsThreadAndGoesOutOnceTheLinkIsBack() async {
        // Arrange
        let archive = temporaryArchive()
        defer { archive.forget() }
        let earlier = Gateway()
        standardAnswers(earlier)
        await connected(earlier)
        await makeModel(earlier, archive: archive).refresh()
        await eventually("the archive is written") { archive.read(.family) != nil }
        let gateway = Gateway()
        standardAnswers(gateway)
        let room = makeModel(gateway, archive: archive)
        await room.restore()

        // Act
        let isKept = await room.send("On my way", in: .family, waitsForLink: true)
        let waited = room.thread(.family).messages.last?.status
        await connected(gateway)
        await room.refresh()

        // Assert
        XCTAssertFalse(isKept)
        XCTAssertEqual(waited, .waiting, "the message never showed as waiting for the link")
        XCTAssertEqual(gateway.requests("household-app.send").map { $0.params["text"]?.stringValue }, ["On my way"])
        XCTAssertEqual(room.thread(.family).messages.last?.text, "On my way")
        XCTAssertEqual(room.thread(.family).messages.last?.status, .sent)
    }

    func testAMessageWaitingWhenTheAppClosedGoesOutAfterItOpensAgain() async {
        // Arrange
        let archive = temporaryArchive()
        defer { archive.forget() }
        let earlier = Gateway()
        standardAnswers(earlier)
        await connected(earlier)
        await makeModel(earlier, archive: archive).refresh()
        await eventually("the archive is written") { archive.read(.family) != nil }
        let closed = makeModel(Gateway(), archive: archive)
        await closed.restore()
        await closed.send("Picked up the milk", in: .family, waitsForLink: true)
        await eventually("the waiting message is kept") { archive.readWaiting().map(\.text) == ["Picked up the milk"] }

        // Act
        let gateway = Gateway()
        standardAnswers(gateway)
        let reopened = makeModel(gateway, archive: archive)
        await reopened.restore()
        let shown = reopened.thread(.family).messages.last
        await connected(gateway)
        await reopened.refresh()

        // Assert
        XCTAssertEqual(shown?.text, "Picked up the milk")
        XCTAssertEqual(shown?.status, .waiting)
        XCTAssertEqual(gateway.requests("household-app.send").map { $0.params["text"]?.stringValue }, ["Picked up the milk"])
        XCTAssertEqual(reopened.thread(.family).messages.last?.status, .sent)
        await eventually("nothing waits any more") { archive.readWaiting().isEmpty }
    }

    func testMessagesThatWaitedGoOutInTheOrderTheyWereSaid() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        gateway.connection.stop()
        await eventually("the link is down") { gateway.connection.state != .connected }

        // Act
        await room.send("First", in: .direct, waitsForLink: true)
        await room.send("Second", in: .family, waitsForLink: true)
        await connected(gateway)
        await room.refresh()

        // Assert
        XCTAssertEqual(gateway.requests("household-app.send").compactMap { $0.params["text"]?.stringValue }.suffix(2), ["First", "Second"])
        XCTAssertEqual(room.thread(.direct).messages.last?.status, .sent)
        XCTAssertEqual(room.thread(.family).messages.last?.status, .sent)
    }

    /// Siri, a call and a share need their answer now, so with no link theirs fails as before
    /// rather than going out hours later.
    func testASendThatCannotWaitFailsWithNoLink() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        gateway.connection.stop()
        await eventually("the link is down") { gateway.connection.state != .connected }

        // Act
        let isKept = await room.send("What is on tomorrow?", in: .direct)
        await connected(gateway)
        await room.refresh()

        // Assert
        XCTAssertFalse(isKept)
        guard case .failed = room.thread(.direct).messages.last?.status else {
            return XCTFail("a send that cannot wait did not fail with no link")
        }
        XCTAssertFalse(gateway.requests("household-app.send").contains { $0.params["text"]?.stringValue == "What is on tomorrow?" })
    }

    func testARefusedSendKeepsItsBubbleAndARetrySendsTheSameMessage() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.send"] = { Self.refused($0, "attachment not received") }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        await room.send("hello", in: .family)
        let id = "m-00000000-0000-4000-8000-000000000001"
        XCTAssertEqual(room.thread(.family).messages.last?.status, .failed("attachment not received"))

        standardAnswers(gateway)
        await room.retry(id, in: .family)
        XCTAssertEqual(gateway.requests("household-app.send").map { $0.params["id"]?.stringValue }, [id, id])
        XCTAssertEqual(gateway.requests("household-app.send").last?.params["signature"]?.stringValue, "phone-signature-1", "the same signed message, not a new one")
        XCTAssertEqual(room.thread(.family).messages.last?.status, .sent)
    }

    func testAVoiceNoteIsUploadedInChunksThenSentByItsHash() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        let hash = String(repeating: "c", count: 64)
        gateway.answers["household-app.upload"] = { request in
            let offset = request.params["offset"]?.intValue ?? 0
            let data = Data(base64Encoded: request.params["data"]?.stringValue ?? "") ?? Data()
            let total = request.params["total"]?.intValue ?? 0
            let received = offset + data.count
            return received < total
                ? Self.ok(request, #"{"complete":false,"received":\#(received)}"#)
                : Self.ok(request, #"{"complete":true,"received":\#(received),"id":"\#(hash)","bytes":\#(total)}"#)
        }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let audio = Data(repeating: 7, count: GatewayConnection.roomChunkBytes * 2 + 10)

        await room.send("", in: .family, attachments: [
            RoomAttachment(data: audio, kind: .voice, mime: "audio/mp4", durationMs: 3200, waveform: [0.2, 0.8]),
        ])

        let uploads = gateway.requests("household-app.upload")
        XCTAssertEqual(uploads.map { $0.params["offset"]?.intValue }, [0, GatewayConnection.roomChunkBytes, GatewayConnection.roomChunkBytes * 2])
        XCTAssertEqual(Set(uploads.compactMap { $0.params["uploadId"]?.stringValue }).count, 1)
        let media = gateway.requests("household-app.send").last?.params["media"]?.arrayValue?.first
        XCTAssertEqual(media?["id"]?.stringValue, hash)
        XCTAssertEqual(media?["kind"]?.stringValue, "voice")
        XCTAssertEqual(media?["durationMs"]?.intValue, 3200)
        XCTAssertEqual(gateway.signed.last?.components(separatedBy: "\n")[5], hash, "the signature covers the attachment")
    }

    func testSeveralAttachmentsAreEachUploadedThenSentTogetherInOneSignedMessage() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.upload"] = { request in
            let data = Data(base64Encoded: request.params["data"]?.stringValue ?? "") ?? Data()
            let hash = String(repeating: String(data.first ?? 0), count: 64)
            return Self.ok(request, #"{"complete":true,"received":\#(data.count),"id":"\#(hash)","bytes":\#(data.count)}"#)
        }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        await room.send("From the beach", in: .family, attachments: [
            RoomAttachment(data: Data(repeating: 1, count: 30), kind: .photo, mime: "image/jpeg", width: 1600, height: 1200),
            RoomAttachment(data: Data(repeating: 2, count: 40), kind: .video, mime: "video/quicktime", durationMs: 24_000, width: 1920, height: 1080),
            RoomAttachment(data: Data(repeating: 3, count: 50), kind: .file, mime: "text/vcard", name: "Rosa.vcf"),
        ])

        let uploads = gateway.requests("household-app.upload")
        XCTAssertEqual(Set(uploads.compactMap { $0.params["uploadId"]?.stringValue }).count, 3, "one upload each")
        let sends = gateway.requests("household-app.send")
        XCTAssertEqual(sends.count, 1, "all three in one message")
        let media = sends.last?.params["media"]?.arrayValue ?? []
        XCTAssertEqual(media.compactMap { $0["kind"]?.stringValue }, ["photo", "video", "file"])
        XCTAssertEqual(media.compactMap { $0["id"]?.stringValue }, ["1", "2", "3"].map { String(repeating: $0, count: 64) })
        XCTAssertEqual(media[1]["durationMs"]?.intValue, 24_000)
        XCTAssertEqual(media[1]["width"]?.intValue, 1920)
        XCTAssertEqual(media[2]["name"]?.stringValue, "Rosa.vcf")
        let ids = ["1", "2", "3"].map { String(repeating: $0, count: 64) }.joined(separator: ",")
        XCTAssertEqual(gateway.signed.last?.components(separatedBy: "\n")[5], ids, "the signature covers all three, in order")
        XCTAssertEqual(room.thread(.family).messages.last?.status, .sent)
    }

    func testAChangedEventCatchesUpFromTheLastRevision() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.syncPage(rev: 7, entries: "[\(Self.messageEntry("m-7", rev: 7, text: "Dinner at seven"))]"))
        }

        room.handle(GatewayEvent(event: RoomEvent.changedName, payload: .object(["rev": .number(7)]), seq: 1))

        await eventually("caught up") { room.rev == 7 }
        XCTAssertEqual(gateway.requests("household-app.sync").last?.params["since"]?.intValue, 6)
        XCTAssertEqual(room.thread(.family).messages.last?.text, "Dinner at seven")
    }

    func testCatchingUpFollowsEveryPage() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.sync"] = { request in
            request.params["since"]?.intValue == 0
                ? Self.ok(request, Self.syncPage(rev: 1, entries: "[\(Self.messageEntry("m-1", rev: 1))]", hasMore: true))
                : Self.ok(request, Self.syncPage(rev: 2, entries: "[\(Self.messageEntry("m-2", rev: 2))]"))
        }
        gateway.answers["household-app.history"] = { Self.ok($0, Self.emptyHistory) }
        await connected(gateway)
        let room = makeModel(gateway)

        await room.refresh()

        XCTAssertEqual(room.thread(.family).messages.map(\.id), ["m-1", "m-2"])
        XCTAssertEqual(room.rev, 2)
    }

    /// A change told while a catch-up reads its last page starts its own catch-up only once
    /// that page's pass is over, and is followed all the same.
    func testAChangeToldAsACatchUpEndsIsFollowedToo() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.sync"] = { request in
            request.params["since"]?.intValue == 0
                ? Self.ok(request, Self.syncPage(rev: 1, entries: "[\(Self.messageEntry("m-1", rev: 1))]"))
                : Self.ok(request, Self.syncPage(rev: 2, entries: "[\(Self.messageEntry("m-2", rev: 2))]"))
        }
        await connected(gateway)
        let room = makeModel(gateway)
        room.onParticipantsChanged = { [weak room] in
            room?.handle(GatewayEvent(event: RoomEvent.changedName, payload: .object(["rev": .number(2)]), seq: 1))
        }

        await room.catchUp()

        await eventually("caught up") { room.rev == 2 }
        XCTAssertEqual(room.thread(.family).messages.map(\.id), ["m-1", "m-2"])
    }

    /// A call that ended is signed by this phone and sent with its messages, and the one
    /// call row the gateway answers with takes their place in the thread.
    func testLoggingACallSignsItAndShowsOneRowInPlaceOfItsMessages() async throws {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.syncPage(rev: 2, entries: "[\(Self.messageEntry("d-1", rev: 1, author: "franco", conversation: "direct")),\(Self.messageEntry("a-1", rev: 2, author: "corey", conversation: "direct"))]"))
        }
        gateway.answers["household-app.call.end"] = { request in
            Self.ok(request, #"{"entry":{"id":"call:c-1","rev":3,"kind":"call","conversation":"direct","author":"franco","at":1792018800000,"endedAt":1792019047000,"with":"corey","turnIds":["d-1","a-1"],"transcript":[{"author":"franco","text":"hello","at":1792018800000}],"isCut":false,"origin":"local"}}"#)
        }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.catchUp()

        // Act
        let isLogged = await room.logCall(
            id: "c-1",
            startedAt: Date(timeIntervalSince1970: 1_792_018_800),
            endedAt: Date(timeIntervalSince1970: 1_792_019_047),
            turns: ["d-1", "a-1"],
            setup: Self.callSetup
        )

        // Assert
        XCTAssertTrue(isLogged)
        XCTAssertEqual(gateway.signed.last, "household-app/call/v1\nc-1\n1792018800000\n1792019047000\nd-1,a-1")
        let sent = try XCTUnwrap(gateway.requests("household-app.call.end").last)
        XCTAssertEqual(sent.params["turns"], .array([.string("d-1"), .string("a-1")]))
        XCTAssertEqual(sent.params["signature"]?.stringValue, "phone-signature-\(gateway.signed.count)")
        XCTAssertEqual(sent.params["setup"], Self.callSetup.params, "how the call came up goes beside what is signed")
        XCTAssertEqual(room.thread(.direct).messages.map(\.id), ["call:c-1"])
    }

    /// A call through CallKit that connected as its sound came, 0.4 s after the tap.
    private static let callSetup: CallSetup = {
        let tap = Date(timeIntervalSince1970: 1_792_018_799)
        var state = CallState()
        state.handle(.link(isUp: true), at: tap)
        state.handle(.audio(isActive: true), at: tap.addingTimeInterval(0.4))
        var placement = CallPlacement()
        _ = placement.handle(.placed(hasCallKit: true))
        return CallSetup(build: "18", tappedAt: tap, state: state, placement: placement, firstSentAt: nil, firstReplyAt: nil)
    }()

    func testACallTheGatewayCannotLogLeavesItsMessagesAsTheyAre() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.syncPage(rev: 1, entries: "[\(Self.messageEntry("d-1", rev: 1, author: "franco", conversation: "direct"))]"))
        }
        gateway.answers["household-app.call.end"] = { Self.refused($0, "unknown method: household-app.call.end") }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.catchUp()

        // Act
        let isLogged = await room.logCall(id: "c-1", startedAt: Date(timeIntervalSince1970: 1_792_018_800), endedAt: Date(timeIntervalSince1970: 1_792_018_860), turns: ["d-1"], setup: Self.callSetup)

        // Assert
        XCTAssertFalse(isLogged)
        XCTAssertEqual(room.thread(.direct).messages.map(\.id), ["d-1"])
    }

    /// A catch-up or a reconnect that brings nothing new never redraws the thread, the
    /// people in it or Chats.
    func testACatchUpThatBringsNothingNewTellsTheScreenNothing() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        // Nothing after whatever revision the phone asks from, as a gateway answers when
        // nothing happened, and each conversation's newest page with the same people on it.
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.syncPage(rev: request.params["since"]?.intValue ?? 0))
        }
        gateway.answers["household-app.history"] = { request in
            let conversation = request.params["conversation"]?.stringValue ?? "family"
            let newest = Self.messageEntry(conversation + "-1", rev: 1, conversation: conversation)
            let page = Self.syncPage(rev: 1).replacingOccurrences(
                of: #""entries":[],"rev":1,"hasMore":false"#,
                with: #""messages":[\#(newest)],"hasMore":false,"reactions":{},"reads":[]"#
            )
            return Self.ok(request, page)
        }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        nonisolated(unsafe) var isTold = false
        withObservationTracking {
            _ = room.thread(.family)
            _ = room.thread(.direct)
            _ = room.participants
            _ = room.me
            _ = room.isAvailable
            _ = room.rev
        } onChange: {
            isTold = true
        }

        // Act
        await room.catchUp()
        await room.refresh()

        // Assert
        XCTAssertFalse(isTold)
    }

    /// What a page brings is made ready before it shows, so a bubble never draws empty first.
    func testArrivingMessagesArePreparedBeforeTheyShow() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.history"] = { Self.ok($0, Self.emptyHistory) }
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.syncPage(rev: 1, entries: "[\(Self.messageEntry("a-1", rev: 1, author: "corey", text: "**Dinner** at seven"))]"))
        }
        await connected(gateway)
        let room = makeModel(gateway)
        nonisolated(unsafe) var prepared: [String] = []
        nonisolated(unsafe) var wasShownWhenPrepared = true
        room.prepare = { messages in
            prepared += messages.map(\.text)
            wasShownWhenPrepared = room.thread(.family).messages.contains { $0.id == "a-1" }
        }

        // Act
        await room.refresh()

        // Assert
        XCTAssertEqual(prepared, ["**Dinner** at seven"])
        XCTAssertFalse(wasShownWhenPrepared)
        XCTAssertEqual(room.thread(.family).messages.map(\.id), ["a-1"])
    }

    /// A burst of streamed words reaches the thread as one change, in order.
    func testABurstOfStreamedWordsRedrawsTheThreadOnce() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        nonisolated(unsafe) var changes = 0
        func track() {
            withObservationTracking {
                _ = room.thread(.family)
            } onChange: {
                changes += 1
            }
        }
        track()

        // Act
        for (seq, words) in ["Tonight ", "is ", "pasta."].enumerated() {
            room.handle(GatewayEvent(event: "chat", payload: .object([
                "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family"),
                "seq": .number(Double(seq + 1)), "state": .string("delta"), "deltaText": .string(words),
            ]), seq: seq + 3))
        }
        await eventually("streamed in") { room.thread(.family).messages.last?.text == "Tonight is pasta." }

        // Assert
        XCTAssertEqual(changes, 1)
    }

    /// Words still waiting when the reply's end arrives are in the bubble it ends.
    func testWordsWaitingWhenTheReplyEndsAreNotLost() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        // Act
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family"),
            "seq": .number(1), "state": .string("delta"), "deltaText": .string("Done."),
        ]), seq: 3))
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family"),
            "seq": .number(2), "state": .string("final"),
        ]), seq: 4))

        // Assert
        let last = room.thread(.family).messages.last
        XCTAssertEqual(last?.text, "Done.")
        XCTAssertNotEqual(last?.status, .streaming)
    }

    /// A reply that has finished streaming is made ready to draw before the thread shows it,
    /// whole, and its run's end is not held up by that.
    func testAFinishedReplyIsReadiedBeforeTheThreadShowsIt() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        var readied: [[RoomMessage]] = []
        var letGo: CheckedContinuation<Void, Never>?
        room.prepare = { messages in
            readied.append(messages)
            await withCheckedContinuation { letGo = $0 }
        }

        // Act
        room.handle(delta("Tonight is pasta.", seq: 1))
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family"),
            "seq": .number(2), "state": .string("final"),
        ]), seq: 4))
        await eventually("the reply is being readied") { letGo != nil }

        // Assert
        XCTAssertEqual(room.thread(.family).messages.last?.status, .sent, "the run ended at once")
        XCTAssertEqual(room.readying(in: .family), ["run:run-9"])
        XCTAssertEqual(room.readying(in: .direct), [])
        XCTAssertEqual(readied.map { $0.map(\.text) }, [["Tonight is pasta."]])
        letGo?.resume()
        await eventually("the reply is ready") { room.readying(in: .family).isEmpty }
    }

    private func delta(_ words: String, seq: Int) -> GatewayEvent {
        GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family"),
            "seq": .number(Double(seq)), "state": .string("delta"), "deltaText": .string(words),
        ]), seq: seq + 2)
    }

    func testLongReplyEventsKeepEveryWordThroughFinalPersistenceAndReopening() async throws {
        for conversation in [RoomConversation.direct, .family] {
            let gateway = Gateway()
            standardAnswers(gateway)
            await connected(gateway)
            let room = makeModel(gateway)
            await room.refresh()
            let sessionKey = conversation == .direct
                ? "agent:main:household:direct:franco" : "agent:main:household:group:family"
            let opening = String(repeating: "A paragraph with **Markdown**, an emoji 🏡 and every original word.\n\n", count: 170)
            let ending = "Unique final paragraph from the long event contract 9ac4."
            let expected = opening + ending
            XCTAssertGreaterThan(expected.utf16.count, 8_000)

            for (index, change) in [("Superseded draft", false), (opening, true), (ending, false)].enumerated() {
                room.handle(GatewayEvent(event: "chat", payload: .object([
                    "runId": .string("long-event-run"), "sessionKey": .string(sessionKey),
                    "seq": .number(Double(index + 1)), "state": .string("delta"),
                    "deltaText": .string(change.0), "replace": .bool(change.1),
                ]), seq: index + 10))
            }
            room.handle(GatewayEvent(event: "chat", payload: .object([
                "runId": .string("long-event-run"), "sessionKey": .string(sessionKey),
                "seq": .number(4), "state": .string("final"),
            ]), seq: 14))
            XCTAssertEqual(room.thread(conversation).messages.last?.text, expected)
            XCTAssertEqual(room.thread(conversation).messages.last?.status, .sent)

            let entry: JSONValue = .object([
                "id": .string("long-kept"), "rev": .number(7), "kind": .string("message"),
                "conversation": .string(conversation.rawValue), "author": .string("corey"),
                "at": .number(1_792_018_800_000), "origin": .string("local"),
                "text": .string(expected), "media": .array([]), "runId": .string("long-event-run"),
            ])
            let entries = String(decoding: try JSONEncoder().encode(JSONValue.array([entry])), as: UTF8.self)
            gateway.answers["household-app.sync"] = { request in
                Self.ok(request, Self.syncPage(rev: 7, entries: entries))
            }
            await room.catchUp()
            XCTAssertEqual(room.thread(conversation).messages.last?.id, "long-kept")
            XCTAssertEqual(room.thread(conversation).messages.last?.text, expected)
            XCTAssertEqual(room.thread(conversation).messages.last?.bubbleId, "run:long-event-run")
            let page: JSONValue = .object([
                "messages": .array([entry]), "hasMore": .bool(false), "reactions": .object([:]),
                "reads": .array([]), "participants": .array([]),
                "self": .object(["person": .string("franco"), "assistant": .string("corey")]),
                "sessionKeys": .object([conversation.rawValue: .string(sessionKey)]),
            ])
            let history = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
            gateway.answers["household-app.history"] = { request in
                Self.ok(request, request.params["conversation"]?.stringValue == conversation.rawValue ? history : Self.emptyHistory)
            }
            let reopened = makeModel(gateway)
            await reopened.refresh()
            XCTAssertEqual(reopened.thread(conversation).messages.last?.text, expected)
            XCTAssertEqual(reopened.thread(conversation).messages.last?.status, .sent)
        }
    }

    /// However fast a reply's pieces come, its thread changes at most once in each
    /// `streamInterval`, and the last pieces are in it once the burst is over.
    func testAStreamingReplyChangesItsThreadAtMostAboutTwentyTimesASecond() async throws {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        nonisolated(unsafe) var changes = 0
        func track() {
            withObservationTracking {
                _ = room.thread(.family)
            } onChange: {
                changes += 1
                Task { @MainActor in
                    track()
                }
            }
        }
        track()
        let clock = ContinuousClock()
        let started = clock.now
        var pieces: [String] = []

        // Act: a piece every few milliseconds for 200 milliseconds.
        while clock.now - started < .milliseconds(200) {
            pieces.append("w\(pieces.count) ")
            room.handle(delta(pieces[pieces.count - 1], seq: pieces.count))
            try await Task.sleep(for: .milliseconds(4))
        }
        let burst = clock.now - started
        await eventually("the last pieces streamed in") { room.thread(.family).messages.last?.text == pieces.joined() }

        // Assert: each change waited a whole interval after the one before it, so by the
        // burst's end there were at most that many intervals' worth, and one more after.
        XCTAssertLessThanOrEqual(changes, Int(burst / RoomModel.streamInterval) + 1, "\(changes) changes from \(pieces.count) pieces in \(burst)")
        XCTAssertGreaterThanOrEqual(changes, 2, "a long reply shows as it arrives, not only at its end")
    }

    /// The pins on Chats read the summaries, and its shared strip and the widgets what was
    /// kept, so a reply streaming in redraws none of them.
    func testAStreamedWordTellsNobodyWatchingTheSummariesOrWhatWasKept() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let before = room.summary(.family)
        nonisolated(unsafe) var isTold = false
        withObservationTracking {
            _ = room.summary(.family)
            _ = room.summary(.direct)
            _ = room.kept(.family)
            _ = room.kept(.direct)
        } onChange: {
            isTold = true
        }

        // Act
        room.handle(delta("Tonight ", seq: 1))
        room.handle(delta("is pasta.", seq: 2))
        await eventually("streamed in") { room.thread(.family).messages.last?.text == "Tonight is pasta." }

        // Assert
        XCTAssertFalse(isTold)
        XCTAssertEqual(room.summary(.family), before)
    }

    func testSomeoneTypingOrAMessageTheGatewayKeptChangesTheSummary() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        XCTAssertEqual(room.summary(.family).unread, 2)
        nonisolated(unsafe) var isTold = false
        withObservationTracking {
            _ = room.summary(.family)
        } onChange: {
            isTold = true
        }

        // Act
        room.handle(GatewayEvent(event: RoomEvent.typingName, payload: .object(["conversation": .string("family"), "author": .string("denise"), "active": .bool(true)]), seq: 1))
        let typing = room.summary(.family)
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 7, entries: "[\(Self.messageEntry("m-7", rev: 7, author: "denise", text: "On my way"))]")) }
        await room.catchUp()

        // Assert
        XCTAssertTrue(isTold)
        XCTAssertTrue(typing.isTyping)
        let summary = room.summary(.family)
        XCTAssertEqual(summary.unread, 3)
        XCTAssertEqual(room.kept(.family).messages.last?.id, "m-7")
        room.reset()
        XCTAssertEqual(room.summary(.family), .empty)
    }

    func testSomeoneTypingShowsAndStopsShowing() async {
        let gateway = Gateway()
        let room = makeModel(gateway)
        room.handle(GatewayEvent(event: RoomEvent.typingName, payload: .object(["conversation": .string("family"), "author": .string("denise"), "active": .bool(true)]), seq: 1))
        XCTAssertEqual(room.typing(in: .family), ["denise"])
        room.handle(GatewayEvent(event: RoomEvent.typingName, payload: .object(["conversation": .string("family"), "author": .string("denise"), "active": .bool(false)]), seq: 2))
        XCTAssertEqual(room.typing(in: .family), [])
    }

    func testTheScreenIsToldWhenSomeoneStartsTyping() async {
        let gateway = Gateway()
        let room = makeModel(gateway)
        nonisolated(unsafe) var isTold = false
        withObservationTracking {
            _ = room.typing(in: .family)
        } onChange: {
            isTold = true
        }

        room.handle(GatewayEvent(event: RoomEvent.typingName, payload: .object(["conversation": .string("family"), "author": .string("denise"), "active": .bool(true)]), seq: 1))

        XCTAssertTrue(isTold, "a typing bubble the screen is never told about never shows")
    }

    func testTypingThatWasNeverStoppedFadesAfterThirtySeconds() async {
        let gateway = Gateway()
        let room = makeModel(gateway)
        room.handle(GatewayEvent(event: RoomEvent.typingName, payload: .object(["conversation": .string("family"), "author": .string("gia"), "active": .bool(true)]), seq: 1))
        clock = clock.addingTimeInterval(31)
        XCTAssertEqual(room.typing(in: .family), [])
    }

    /// The gateway says the assistant is typing until it has kept the reply, which may come
    /// after the run's end: the dots never come back under the finished reply meanwhile.
    func testTheRunsEndStopsItsAssistantTyping() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        room.handle(GatewayEvent(event: RoomEvent.typingName, payload: .object(["conversation": .string("family"), "author": .string("corey"), "active": .bool(true)]), seq: 3))
        room.handle(GatewayEvent(event: RoomEvent.typingName, payload: .object(["conversation": .string("family"), "author": .string("denise"), "active": .bool(true)]), seq: 4))

        // Act
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family"),
            "seq": .number(1), "state": .string("final"),
        ]), seq: 5))

        // Assert
        XCTAssertEqual(room.typing(in: .family), ["denise"], "Corey's run is over; Denise still types")
    }

    func testTheAssistantsStreamedReplyGrowsInItsConversation() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family"),
            "seq": .number(1), "state": .string("delta"), "deltaText": .string("On it"),
        ]), seq: 3))

        await eventually("streamed in") { room.thread(.family).messages.last?.text == "On it" }
        XCTAssertEqual(room.thread(.family).messages.last?.author, "corey")
        XCTAssertEqual(room.thread(.family).messages.last?.status, .streaming)
        XCTAssertEqual(room.typing(in: .family), [], "a reply that is already arriving is not also typing")
    }

    func testRefreshFollowsBothConversationsSoTheirRepliesStreamAndTheirToolsShow() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["sessions.messages.subscribe"] = { request in
            Self.ok(request, #"{"subscribed":true,"key":"\#(request.params["key"]?.stringValue ?? "")"}"#)
        }
        await connected(gateway)
        let room = makeModel(gateway)

        await room.refresh()

        await eventually("followed") { gateway.requests("sessions.messages.subscribe").count == 2 }
        XCTAssertEqual(
            Set(gateway.requests("sessions.messages.subscribe").compactMap { $0.params["key"]?.stringValue }),
            ["agent:main:household:group:family", "agent:main:household:direct:franco"]
        )
    }

    /// Leo's own family-room turns run in a session of their own on Corey's gateway, so
    /// Corey's replies to him there stream from it. Until 19 October the phone followed only
    /// the room's shared session, and those replies arrived whole after the dots.
    func testTheOwnersOwnFamilyRoomRepliesStreamIntoTheFamilyRoomWithTheirSteps() async {
        // Arrange
        let owners = "agent:main:household:group:family:sender:franco"
        let withOwners = { (page: String) in
            page.replacingOccurrences(of: #""sessionKeys":{"#, with: #""ownersFamilySession":"\#(owners)","sessionKeys":{"#)
        }
        let gateway = Gateway()
        gateway.answers["household-app.history"] = { request in Self.ok(request, withOwners(Self.emptyHistory)) }
        gateway.answers["household-app.sync"] = { request in Self.ok(request, withOwners(Self.syncPage(rev: 1))) }
        gateway.answers["sessions.messages.subscribe"] = { request in
            Self.ok(request, #"{"subscribed":true,"key":"\#(request.params["key"]?.stringValue ?? "")"}"#)
        }
        await connected(gateway)
        let room = makeModel(gateway)

        // Act
        await room.refresh()
        await eventually("followed") { gateway.requests("sessions.messages.subscribe").count == 3 }
        room.handle(toolStep("start", "web_search", call: "call-1", session: owners))
        let stepped = room.activity(in: .family)
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string(owners),
            "seq": .number(1), "state": .string("delta"), "deltaText": .string("Mochi was 410 g"),
        ]), seq: 3))

        // Assert
        XCTAssertEqual(
            Set(gateway.requests("sessions.messages.subscribe").compactMap { $0.params["key"]?.stringValue }),
            ["agent:main:household:group:family", "agent:main:household:direct:franco", owners]
        )
        XCTAssertEqual(stepped, .webSearch)
        XCTAssertNil(room.activity(in: .direct))
        await eventually("streamed in") { room.thread(.family).messages.last?.text == "Mochi was 410 g" }
        XCTAssertEqual(room.thread(.family).messages.last?.author, "corey")
        XCTAssertEqual(room.thread(.family).messages.last?.status, .streaming)
        XCTAssertTrue(room.thread(.direct).messages.isEmpty)
    }

    func testAGatewayThatNamesNoOwnersSessionStreamsTheRoomsAloneAsBefore() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:household:group:family:sender:franco"),
            "seq": .number(1), "state": .string("delta"), "deltaText": .string("On it"),
        ]), seq: 3))
        // Streamed words reach the thread after RoomModel.streamInterval; wait well past it.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(room.thread(.family).messages.contains { $0.text == "On it" })
    }

    private func toolStep(_ phase: String, _ name: String = "exec", call: String, command: String? = nil, session: String = "agent:main:household:direct:franco", run: String = "run-7") -> GatewayEvent {
        var data: [String: JSONValue] = ["phase": .string(phase), "name": .string(name), "toolCallId": .string(call)]
        if let command {
            data["args"] = .object(["command": .string(command)])
        }
        return GatewayEvent(event: "agent", payload: .object([
            "runId": .string(run), "stream": .string("tool"), "seq": .number(1),
            "sessionKey": .string(session), "data": .object(data),
        ]), seq: 20)
    }

    func testAToolTheRunUsesShowsWhatTheAssistantIsDoingUntilItIsDone() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        XCTAssertNil(room.activity(in: .direct))

        room.handle(toolStep("start", call: "call-1", command: "gog calendar events --today"))
        XCTAssertEqual(room.activity(in: .direct), .calendar)
        XCTAssertNil(room.activity(in: .family))

        room.handle(toolStep("update", call: "call-1"))
        room.handle(toolStep("result", call: "call-0"))
        XCTAssertEqual(room.activity(in: .direct), .calendar, "another call's result says nothing about this one")
        room.handle(toolStep("result", call: "call-1"))
        XCTAssertNil(room.activity(in: .direct), "thinking again")

        room.handle(toolStep("start", "web_search", call: "call-2"))
        XCTAssertEqual(room.activity(in: .direct), .webSearch)
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-7"), "sessionKey": .string("agent:main:household:direct:franco"),
            "seq": .number(9), "state": .string("final"),
        ]), seq: 21))
        XCTAssertNil(room.activity(in: .direct), "the run is over")

        room.handle(toolStep("start", "web_search", call: "call-3", session: "agent:main:main"))
        XCTAssertNil(room.activity(in: .direct), "another session's tools are not this thread's")

        room.handle(toolStep("start", "recall", call: "call-4"))
        room.reset()
        XCTAssertNil(room.activity(in: .direct))
    }

    /// A tool done in a blink stays on the typing bubble's working line long enough to read,
    /// the next step waits its turn, Talk hears at once what the run is doing, and the run's
    /// end takes the line away for the reply.
    func testAQuickStepHoldsTheWorkingLineUntilItCanBeRead() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        // Act
        room.handle(toolStep("start", call: "call-1", command: "gog calendar events --today"))
        room.handle(toolStep("result", call: "call-1"))
        room.handle(toolStep("start", "web_search", call: "call-2"))

        // Assert
        XCTAssertEqual(room.activity(in: .direct), .webSearch, "Talk hears the run at once")
        XCTAssertEqual(room.shownStep(in: .direct), .calendar, "the calendar step is still held")
        clock = clock.addingTimeInterval(ToolSteps.held)
        await eventually("the web search's turn") { room.shownStep(in: .direct) == .webSearch }
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-7"), "sessionKey": .string("agent:main:household:direct:franco"),
            "seq": .number(9), "state": .string("final"),
        ]), seq: 21))
        XCTAssertNil(room.shownStep(in: .direct), "the reply never waits on a step")
    }

    func testAToolTheRunUsesInTheFamilyRoomShowsThereOnly() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        room.handle(toolStep("start", "web_search", call: "call-1", session: "agent:main:household:group:family"))

        XCTAssertEqual(room.activity(in: .family), .webSearch)
        XCTAssertNil(room.activity(in: .direct))
        room.handle(toolStep("result", "web_search", call: "call-1", session: "agent:main:household:group:family"))
        XCTAssertNil(room.activity(in: .family))
    }

    /// The owner wants only the reply in his thread: a tool the run uses says what the
    /// assistant is doing in the typing bubble while it runs, and leaves nothing behind.
    func testAToolTheRunUsesNeverLeavesALineInTheThread() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let before = room.direct

        // Act
        room.handle(toolStep("start", call: "call-1", command: "gog calendar events --today"))
        let activityWhileRunning = room.activity(in: .direct)
        room.handle(toolStep("start", "unknown_tool", call: "call-2"))
        room.handle(toolStep("result", call: "call-1"))
        room.handle(toolStep("result", "unknown_tool", call: "call-2"))
        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-7"), "sessionKey": .string("agent:main:household:direct:franco"),
            "seq": .number(9), "state": .string("final"),
        ]), seq: 21))

        // Assert
        XCTAssertEqual(activityWhileRunning, .calendar)
        XCTAssertEqual(room.direct, before, "no step, finished or not, is ever a line in the thread")
        XCTAssertNil(room.activity(in: .direct))
    }

    // MARK: - Approvals

    private static let approvalCard =
        #"{"id":"ap-1","rev":7,"kind":"message","conversation":"direct","author":"corey","at":1792018800000,"origin":"local","text":"Needs your OK: Add to the family calendar","media":[],"replyTo":null,"approval":{"id":"plugin:5f0c","kind":"plugin","title":"Add to the family calendar","decisions":["allow-once","deny"]}}"#

    private func roomWithAnApprovalCard(_ gateway: Gateway) async -> RoomModel {
        standardAnswers(gateway)
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 7, entries: "[\(Self.approvalCard)]")) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        return room
    }

    func testApprovingSignsTheAnswerAndShowsItAtOnce() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.approval.answer"] = { Self.ok($0, #"{"answered":true}"#) }
        let room = await roomWithAnApprovalCard(gateway)
        let card = try XCTUnwrap(room.direct.messages.first { $0.approval != nil })

        await room.answer(card, with: .approve)

        XCTAssertEqual(room.approvalOutcome(of: card.id), .approved)
        XCTAssertEqual(gateway.signed.last, "household-app/approval/v1\nplugin:5f0c\nallow-once")
        let sent = try XCTUnwrap(gateway.requests("household-app.approval.answer").last?.params)
        XCTAssertEqual(sent["messageId"]?.stringValue, "ap-1")
        XCTAssertEqual(sent["decision"]?.stringValue, "allow-once")
        XCTAssertEqual(sent["signature"]?.stringValue, "phone-signature-\(gateway.signed.count)")
        XCTAssertNil(room.approvalRefusals[card.id])
    }

    func testDenyingIsSignedTheSameWay() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.approval.answer"] = { Self.ok($0, #"{"answered":true}"#) }
        let room = await roomWithAnApprovalCard(gateway)
        let card = try XCTUnwrap(room.direct.messages.first { $0.approval != nil })

        await room.answer(card, with: .deny)

        XCTAssertEqual(room.approvalOutcome(of: card.id), .denied)
        XCTAssertEqual(gateway.signed.last, "household-app/approval/v1\nplugin:5f0c\ndeny")
    }

    func testAnAnswerTheGatewayRefusesIsTakenBackAndSaysWhy() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.approval.answer"] = { Self.refused($0, "that approval is no longer waiting") }
        let room = await roomWithAnApprovalCard(gateway)
        let card = try XCTUnwrap(room.direct.messages.first { $0.approval != nil })

        await room.answer(card, with: .approve)

        XCTAssertNil(room.approvalOutcome(of: card.id))
        XCTAssertEqual(room.approvalRefusals[card.id], "that approval is no longer waiting")
    }

    func testWhatTheGatewaySaysAboutACardOutranksThisPhonesAnswer() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.approval.answer"] = { Self.ok($0, #"{"answered":true}"#) }
        let room = await roomWithAnApprovalCard(gateway)
        let card = try XCTUnwrap(room.direct.messages.first { $0.approval != nil })
        await room.answer(card, with: .approve)

        let ended = #"{"id":"approval:ap-1","rev":8,"kind":"approval","conversation":"direct","author":"corey","at":1792018800000,"origin":"local","messageId":"ap-1","state":"expired"}"#
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 8, entries: "[\(ended)]")) }
        await room.catchUp()

        XCTAssertEqual(room.approvalOutcome(of: card.id), .expired)
    }

    func testACardThatHasEndedOrIsNoApprovalIsNeverAnswered() async throws {
        let gateway = Gateway()
        let ended = #"{"id":"approval:ap-1","rev":8,"kind":"approval","conversation":"direct","author":"corey","at":1792018800000,"origin":"local","messageId":"ap-1","state":"denied"}"#
        standardAnswers(gateway)
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 8, entries: "[\(Self.approvalCard),\(ended)]")) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let card = try XCTUnwrap(room.direct.messages.first { $0.approval != nil })
        let ordinary = try XCTUnwrap(room.thread(.family).messages.first)

        await room.answer(card, with: .approve)
        await room.answer(ordinary, with: .approve)

        XCTAssertTrue(gateway.requests("household-app.approval.answer").isEmpty)
        XCTAssertEqual(room.approvalOutcome(of: card.id), .denied)
        room.reset()
        XCTAssertNil(room.approvalOutcome(of: card.id))
    }

    func testAChatEventForAnotherSessionIsNotThisRooms() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let before = room.thread(.family).messages

        room.handle(GatewayEvent(event: "chat", payload: .object([
            "runId": .string("run-9"), "sessionKey": .string("agent:main:main"),
            "seq": .number(1), "state": .string("delta"), "deltaText": .string("elsewhere"),
        ]), seq: 3))

        XCTAssertEqual(room.thread(.family).messages, before)
    }

    func testAGatewayWithoutTheAppChannelSaysSo() async {
        let gateway = Gateway()
        gateway.answers["household-app.history"] = { request in
            #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"unknown method: household-app.history"}}"#
        }
        await connected(gateway)
        let room = makeModel(gateway)

        await room.refresh()

        XCTAssertEqual(room.isAvailable, false)
    }

    func testReadingMarksTheLatestKeptIncomingMessageOnceInEitherConversation() async {
        let scenarios: [(authors: [String], expectedMessageId: String?)] = [
            ([], nil),
            (["franco"], nil),
            (["corey"], "message-1"),
            (["corey", "corey", "franco"], "message-2"),
        ]
        for conversation in RoomConversation.allCases {
            for scenario in scenarios {
                let gateway = Gateway()
                defer { gateway.connection.stop() }
                let entries = scenario.authors.enumerated().map { index, author in
                    Self.messageEntry("message-\(index + 1)", rev: index + 1, author: author, conversation: conversation.rawValue)
                }.joined(separator: ",")
                gateway.answers["household-app.history"] = { Self.ok($0, Self.emptyHistory) }
                gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: scenario.authors.count, entries: "[\(entries)]")) }
                gateway.answers["household-app.read"] = { Self.ok($0, #"{"entry":null}"#) }
                await connected(gateway)
                let room = makeModel(gateway)
                await room.refresh()

                await room.markRead(conversation)
                await room.markRead(conversation)

                let reads = gateway.requests("household-app.read")
                if let expectedMessageId = scenario.expectedMessageId {
                    XCTAssertEqual(reads.count, 1)
                    XCTAssertEqual(reads.first?.params["messageId"]?.stringValue, expectedMessageId)
                    XCTAssertEqual(reads.first?.params["conversation"]?.stringValue, conversation.rawValue)
                } else {
                    XCTAssertTrue(reads.isEmpty)
                }
            }
        }
    }

    #if DEBUG && canImport(UIKit)
    func testReadingADemoConversationClearsOnlyItsUnreadCountAndKeepsItsReadMarker() async throws {
        for conversation in RoomConversation.allCases {
            let transport = DemoGateway()
            let unreadMedia = conversation == .family ? transport.room.voiceNote : transport.room.permissionSlip
            let latest = try XCTUnwrap(transport.room.entries.first { entry in
                entry.media.contains { $0.id == unreadMedia.id }
            })
            if conversation == .direct {
                transport.room.say("I will sign it tonight.", by: DemoRoom.person, in: .direct)
            }
            let connection = GatewayConnection(
                transport: transport,
                credentials: MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t")),
                signer: DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "connect-signature" }
            )
            defer { connection.stop() }
            let room = RoomModel(connection: connection, sign: { _ in "phone-signature" })
            connection.onEvent = { [weak room] in room?.handle($0) }
            connection.start(GatewayConnection.Configuration(
                url: try XCTUnwrap(URL(string: "ws://demo.steward.invalid")),
                client: .stewardPhone(displayName: "test", version: "0.1.0"),
                scopes: OperatorScope.chat,
                locale: "en-US"
            ))
            await eventually("demo connected") { connection.state == .connected }
            await room.refresh()
            XCTAssertEqual(room.summary(conversation).unread, 2)
            XCTAssertEqual(room.thread(conversation).messages.last?.author, DemoRoom.person)
            let otherConversation: RoomConversation = conversation == .family ? .direct : .family
            let otherSummary = room.summary(otherConversation)
            let otherReads = room.thread(otherConversation).reads
            let readCount = transport.room.entries.filter { $0.kind == "read" }.count

            await room.markRead(conversation)
            await room.markRead(conversation)

            await eventually("demo unread count cleared for \(conversation.rawValue)") {
                room.summary(conversation).unread == 0
            }
            XCTAssertEqual(room.thread(conversation).reads[DemoRoom.person], latest.id)
            XCTAssertEqual(room.summary(otherConversation), otherSummary)
            XCTAssertEqual(room.thread(otherConversation).reads, otherReads)
            XCTAssertEqual(transport.room.entries.filter { $0.kind == "read" }.count, readCount + 1)
            let history = try await connection.roomHistory(conversation, before: nil)
            XCTAssertEqual(history.reads.first { $0.author == DemoRoom.person }?.messageId, latest.id)
        }
    }
    #endif

    func testTypingInTheFamilyRoomIsSaidOnceRepeatedAfterTenSecondsAndStoppedOnce() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.typing"] = { Self.ok($0, "{}") }
        await connected(gateway)
        let room = makeModel(gateway)

        // Act
        await room.noteDraft("D", in: .family)
        await room.noteDraft("Din", in: .family)
        clock = clock.addingTimeInterval(RoomModel.typingRefreshSeconds)
        await room.noteDraft("Dinner", in: .family)
        await room.noteDraft("", in: .family)
        await room.noteDraft("", in: .family)

        // Assert
        let said = gateway.requests("household-app.typing").map { $0.params["active"]?.boolValue }
        XCTAssertEqual(said, [true, true, false])
        XCTAssertEqual(gateway.requests("household-app.typing").first?.params["conversation"]?.stringValue, "family")
    }

    func testTypingInTheOwnThreadIsNeverSaid() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.typing"] = { Self.ok($0, "{}") }
        await connected(gateway)
        let room = makeModel(gateway)

        // Act
        await room.noteDraft("What is on tonight?", in: .direct)
        await room.noteDraft("", in: .direct)

        // Assert
        XCTAssertEqual(gateway.requests("household-app.typing").count, 0)
    }

    func testAReactionIsSentAndShownBeforeTheGatewayAnswers() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.react"] = { Self.ok($0, #"{"entry":null}"#) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let target = room.thread(.family).messages[1].id

        await room.react(to: target, with: "😂", in: .family)

        XCTAssertEqual(gateway.requests("household-app.react").last?.params["emoji"]?.stringValue, "😂")
        XCTAssertEqual(room.thread(.family).messages[1].reactions, [RoomReaction(author: "franco", emoji: "😂")])
    }

    func testAskingSendsToTheAssistantsThreadAndReturnsItsNextReply() async throws {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.syncPage(rev: 51, entries: "[\(Self.messageEntry("a-51", rev: 51, author: "corey", conversation: "direct", text: "Your day is clear."))]"))
        }

        async let reply = room.ask("What is on today?")
        await eventually("sent") { !gateway.requests("household-app.send").isEmpty }
        room.handle(GatewayEvent(event: RoomEvent.changedName, payload: .object(["rev": .number(51)]), seq: 9))

        let answer = try await reply
        XCTAssertEqual(answer, "Your day is clear.")
        XCTAssertEqual(gateway.requests("household-app.send").last?.params["conversation"]?.stringValue, "direct")
        XCTAssertEqual(gateway.requests("household-app.send").last?.params["signature"]?.stringValue, "phone-signature-1", "Siri's question is signed like any other")
    }

    func testAskingWhenTheSendIsRefusedSaysWhy() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.send"] = { Self.refused($0, "message too long") }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        do {
            _ = try await room.ask("hello")
            XCTFail("a refused send answered")
        } catch {
            XCTAssertEqual(ErrorText.describe(error), "message too long")
        }
    }

    func testAnAnswerThatNeverComesTimesOut() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        do {
            _ = try await room.ask("hello", timeout: 0.05)
            XCTFail("nothing answered and yet it returned")
        } catch {
            XCTAssertEqual(error as? GatewayConnectionError, .timedOut)
        }
    }

    func testTheWidgetsShowEachConversationsNewestLineOnceTheRoomHasCaughtUp() async throws {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        gateway.answers["household-app.sync"] = { request in
            Self.ok(request, Self.syncPage(rev: 9, entries: "[\(Self.messageEntry("a-8", rev: 8, author: "corey", conversation: "family", text: "In the room")),\(Self.messageEntry("a-9", rev: 9, author: "corey", conversation: "direct", text: "Just for you"))]"))
        }
        await room.catchUp()

        var snapshot = WidgetSnapshot()
        snapshot.show(family: room.family, direct: room.direct, participants: room.participants, me: try XCTUnwrap(room.me))

        XCTAssertEqual(snapshot.direct.lines.last?.text, "Just for you")
        XCTAssertEqual(snapshot.family.lines.last?.text, "In the room")
        XCTAssertEqual(snapshot.faces.map(\.id), ["franco", "corey", "denise", "gia"])
    }

    func testATickedChecklistItemShowsAtOnceAndIsSentForTheAssistant() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.card.tick"] = { Self.ok($0, #"{"kept":true}"#) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let packLunch = ChecklistTick(messageId: "a-7", cardId: "before-trip", item: 1)

        await room.tick(packLunch, isDone: true, in: .direct)

        XCTAssertEqual(room.ticks[packLunch], true)
        let sent = gateway.requests("household-app.card.tick").last?.params
        XCTAssertEqual(sent?["conversation"]?.stringValue, "direct")
        XCTAssertEqual(sent?["messageId"]?.stringValue, "a-7")
        XCTAssertEqual(sent?["cardId"]?.stringValue, "before-trip")
        XCTAssertEqual(sent?["item"]?.intValue, 1)
        XCTAssertEqual(sent?["done"]?.boolValue, true)
    }

    func testATickTheGatewayRefusesIsTakenBack() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.card.tick"] = { Self.refused($0, "no such checklist") }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let packLunch = ChecklistTick(messageId: "a-7", cardId: "before-trip", item: 1)

        await room.tick(packLunch, isDone: true, in: .family)

        XCTAssertNil(room.ticks[packLunch])
        XCTAssertEqual(room.errorText, "no such checklist")
    }

    func testOrderedOnACartCardTellsTheGatewayWhichCardWasCheckedOut() async throws {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.cart.ordered"] = { Self.ok($0, #"{"ordered":3}"#) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        let ordered = try await room.markOrdered(cartIn: "a-12", in: .family)

        XCTAssertEqual(ordered, 3)
        let sent = try XCTUnwrap(gateway.requests("household-app.cart.ordered").last?.params)
        XCTAssertEqual(sent, .object([
            "conversation": .string("family"),
            "messageId": .string("a-12"),
        ]))
    }

    func testOrderedTheGatewayRefusesSaysWhy() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.cart.ordered"] = { Self.refused($0, "Everything on that card was already ordered or removed.") }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        do {
            _ = try await room.markOrdered(cartIn: "a-12", in: .direct)
            XCTFail("a refusal came back as ordered")
        } catch {
            XCTAssertEqual(ErrorText.describe(error), "Everything on that card was already ordered or removed.")
        }
        XCTAssertEqual(gateway.requests("household-app.cart.ordered").last?.params["conversation"]?.stringValue, "direct")
    }

    // MARK: - What a notification's answer needs

    /// A reply from a notification has nobody looking at the room, so the app has to hear
    /// whether it went, to say so when it did not.
    func testSendingSaysWhetherTheGatewayKeptTheMessage() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)

        let isSentBeforeAnyPage = await room.send("hello", in: .family)
        await room.refresh()
        let isSent = await room.send("On my way", in: .family, replyTo: "m-3")
        gateway.answers["household-app.send"] = { Self.refused($0, "message too long") }
        let isRefusedSent = await room.send("and more", in: .family)

        XCTAssertFalse(isSentBeforeAnyPage, "nothing is sent before a page has said who this phone is")
        XCTAssertTrue(isSent)
        XCTAssertEqual(gateway.requests("household-app.send").first?.params["replyTo"]?.stringValue, "m-3")
        XCTAssertNotNil(gateway.requests("household-app.send").first?.params["signature"]?.stringValue, "signed, as the composer sends")
        XCTAssertFalse(isRefusedSent)
    }

    func testAReactionSaysWhetherTheGatewayTookIt() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.react"] = { Self.ok($0, #"{"entry":null}"#) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let target = room.thread(.family).messages[1].id

        let isTaken = await room.react(to: target, with: "\u{2764}\u{FE0F}", in: .family)
        gateway.answers["household-app.react"] = { Self.refused($0, "no such message") }
        let isRefusedTaken = await room.react(to: target, with: "\u{1F44D}", in: .family)

        XCTAssertTrue(isTaken)
        XCTAssertFalse(isRefusedTaken)
    }

    /// The faces a notification shows are drawn again only when somebody or their face changed.
    func testWhoIsInTheRoomIsHandedOnOnlyWhenItChanges() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        var handed = 0
        room.onParticipantsChanged = { handed += 1 }
        await room.refresh()
        XCTAssertGreaterThan(handed, 0)
        XCTAssertEqual(room.participants.count, 4)

        handed = 0
        await room.catchUp()
        XCTAssertEqual(handed, 0, "the same four, with the same faces")

        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 8)) }
        await room.catchUp()
        XCTAssertEqual(handed, 1, "Denise's emoji is gone in this page")
    }

    // MARK: - Sharing

    /// What was shared from another app is sent under its hand-off's id, so sending it
    /// again after the app was stopped half way is the same message to the gateway, and
    /// one the room already shows is not shown twice.
    func testAMessageSentUnderAKeyIsTheSameMessageEachTime() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let key = "6f1c2a9e-0d4b-4c1e-9a57-2b8f0c3d4e5f"

        // Act
        let isSent = await room.send("From the beach", in: .family, key: key)
        let isSentAgain = await room.send("From the beach", in: .family, key: key)

        // Assert
        XCTAssertTrue(isSent)
        XCTAssertTrue(isSentAgain, "the gateway already has it")
        XCTAssertEqual(gateway.requests("household-app.send").map { $0.params["id"]?.stringValue }, ["m-" + key])
        XCTAssertEqual(room.thread(.family).messages.filter { $0.id == "m-" + key }.count, 1)
    }

    /// The share suggestions follow every message this phone's person sends.
    func testTheAppHearsOfEachMessageTheGatewayKeepsFromThisPhone() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        await connected(gateway)
        let room = makeModel(gateway)
        var heard: [RoomConversation] = []
        room.onSent = { heard.append($0) }
        await room.refresh()

        await room.send("What is on today?", in: .direct)
        await room.send("Corey, add eggs", in: .family)
        gateway.answers["household-app.send"] = { Self.refused($0, "message too long") }
        await room.send("and more", in: .family)

        XCTAssertEqual(heard, [.direct, .family], "not the one the gateway refused")
    }

    private static func historyPage(revs: ClosedRange<Int>, hasMore: Bool) -> String {
        let messages = revs.map { messageEntry("m-0000000\($0)", rev: $0, text: "message \($0)") }.joined(separator: ",")
        return #"{"messages":[\#(messages)],"hasMore":\#(hasMore),"reactions":{},"reads":[],"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{"family":"agent:main:household:group:family","direct":"agent:main:household:direct:franco"}}"#
    }

    /// A small history still fits in the recent cache.
    func testLoadingAllReadsEveryOlderPage() async {
        // Arrange
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.history"] = { request in
            guard request.params["conversation"]?.stringValue == "family" else {
                return Self.ok(request, Self.emptyHistory)
            }
            switch request.params["before"]?.intValue {
            case nil:
                return Self.ok(request, Self.historyPage(revs: 5...6, hasMore: true))
            case 5:
                return Self.ok(request, Self.historyPage(revs: 3...4, hasMore: true))
            default:
                return Self.ok(request, Self.historyPage(revs: 1...2, hasMore: false))
            }
        }
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 6)) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        // Act
        await room.loadAll(.family)

        // Assert
        XCTAssertEqual(room.thread(.family).messages.compactMap(\.rev), [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(room.thread(.family).hasOlder)
    }

    func testLoadingAllStopsWhereTheGatewayStopsAnswering() async {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.history"] = { request in
            guard request.params["conversation"]?.stringValue == "family" else {
                return Self.ok(request, Self.emptyHistory)
            }
            return request.params["before"] == nil
                ? Self.ok(request, Self.historyPage(revs: 5...6, hasMore: true))
                : Self.refused(request, "history unavailable")
        }
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 6)) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()

        await room.loadAll(.family)

        XCTAssertEqual(room.thread(.family).messages.compactMap(\.rev), [5, 6])
        XCTAssertEqual(gateway.requests("household-app.history").filter { $0.params["before"] != nil }.count, 1, "asked once, not forever")
    }

    func testOlderReadingWindowDoesNotReplaceLiveMessages() async throws {
        let gateway = Gateway()
        standardAnswers(gateway)
        gateway.answers["household-app.history"] = { request in
            guard request.params["conversation"]?.stringValue == "family" else {
                return Self.ok(request, Self.emptyHistory)
            }
            return Self.ok(request, request.params["before"] == nil
                           ? Self.historyPage(revs: 101...1_100, hasMore: true)
                           : Self.historyPage(revs: 1...100, hasMore: false))
        }
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(rev: 1_100)) }
        await connected(gateway)
        let room = makeModel(gateway)
        await room.refresh()
        let live = room.thread(.family)
        let older = await room.olderWindow(than: live)
        XCTAssertEqual(try XCTUnwrap(older).oldestRev, 1)
        XCTAssertEqual(older?.latestRev, 1_000)
        XCTAssertEqual(room.thread(.family), live)
    }
}
