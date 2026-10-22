// Faces chosen from Photos: a participant's face as the gateway lists it, setting this
// phone's person's face or their assistant's, and the family room's own photo, driven
// over a scripted gateway.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class FacesTests: XCTestCase {
    /// A connected gateway that answers each household-app method from a closure.
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

    private static func ok(_ request: GatewayRequest, _ payload: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":true,"payload":\#(payload)}"#
    }

    private static let hash = String(repeating: "f", count: 64)
    private static let face = #"{"id":"\#(hash)","kind":"photo","mime":"image/jpeg","bytes":2048,"width":512,"height":512}"#

    func testAParticipantsFaceIsReadWithTheParticipants() async throws {
        let json = #"[{"id":"corey","name":"Corey","kind":"assistant","isOwner":false,"emoji":"🦉","avatar":\#(Self.face)},{"id":"gia","name":"Gia","kind":"person","isOwner":false}]"#
        let participants = try JSONDecoder().decode([RoomParticipant].self, from: Data(json.utf8))
        XCTAssertEqual(participants[0].avatar?.id, Self.hash)
        XCTAssertEqual(participants[0].avatar?.kind, .photo)
        XCTAssertNil(participants[1].avatar)
    }

    func testSettingAFaceUploadsThePhotoThenNamesIt() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.upload"] = { request in
            let total = request.params["total"]?.intValue ?? 0
            return Self.ok(request, #"{"complete":true,"received":\#(total),"id":"\#(Self.hash)","bytes":\#(total)}"#)
        }
        gateway.answers["household-app.avatar.set"] = { request in
            Self.ok(request, #"{"participants":[{"id":"corey","name":"Corey","kind":"assistant","isOwner":false,"avatar":\#(Self.face)}]}"#)
        }
        try await gateway.connect()
        let room = RoomModel(connection: gateway.connection, sign: { _ in "signature" })
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 2044)

        try await room.setFace(of: "corey", jpeg: jpeg, side: 512)

        XCTAssertEqual(gateway.requests("household-app.upload").count, 1)
        let named = try XCTUnwrap(gateway.requests("household-app.avatar.set").first?.params)
        XCTAssertEqual(named["participant"]?.stringValue, "corey")
        XCTAssertEqual(named["media"]?["id"]?.stringValue, Self.hash)
        XCTAssertEqual(named["media"]?["kind"]?.stringValue, "photo")
        XCTAssertEqual(named["media"]?["mime"]?.stringValue, "image/jpeg")
        XCTAssertEqual(named["media"]?["width"]?.intValue, 512)
        XCTAssertEqual(room.participant("corey")?.avatar?.id, Self.hash)
    }

    // MARK: - The family room's photo

    private static let me = #""self":{"person":"franco","assistant":"corey"}"#

    private static func syncPage(_ extra: String) -> String {
        #"{"entries":[],"rev":3,"hasMore":false,"participants":[],\#(me),"sessionKeys":{}\#(extra)}"#
    }

    private static func historyPage(_ extra: String) -> String {
        #"{"messages":[],"hasMore":false,"reactions":{},"reads":[],"participants":[],\#(me),"sessionKeys":{}\#(extra)}"#
    }

    func testTheFamilyPhotoDecodesFromEitherPageAndAnOlderGatewayStillDecodes() throws {
        let cases: [(name: String, extra: String, expected: String?)] = [
            ("with it", #","familyAvatar":\#(Self.face)"#, Self.hash),
            ("without it", "", nil),
            ("as null", #","familyAvatar":null"#, nil),
        ]
        for (name, extra, expected) in cases {
            // Act
            let sync = try JSONDecoder().decode(RoomSyncPage.self, from: Data(Self.syncPage(extra).utf8))
            let history = try JSONDecoder().decode(RoomHistoryPage.self, from: Data(Self.historyPage(extra).utf8))

            // Assert
            XCTAssertEqual(sync.familyAvatar?.id, expected, "sync page \(name)")
            XCTAssertEqual(history.familyAvatar?.id, expected, "history page \(name)")
        }
    }

    func testTheRoomKeepsTheFamilyPhotoItsPagesCarryAndForgetsItOnReset() async throws {
        // Arrange
        let gateway = Gateway()
        let withPhoto = #","familyAvatar":\#(Self.face)"#
        gateway.answers["household-app.history"] = { Self.ok($0, Self.historyPage(withPhoto)) }
        gateway.answers["household-app.sync"] = { Self.ok($0, Self.syncPage(withPhoto)) }
        try await gateway.connect()
        let room = RoomModel(connection: gateway.connection, sign: { _ in "signature" })

        // Act
        await room.refresh()

        // Assert
        XCTAssertEqual(room.familyAvatar?.id, Self.hash)
        room.reset()
        XCTAssertNil(room.familyAvatar)
    }

    func testSettingTheFamilyPhotoNamesTheFamilyAndShowsItAtOnce() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.upload"] = { request in
            let total = request.params["total"]?.intValue ?? 0
            return Self.ok(request, #"{"complete":true,"received":\#(total),"id":"\#(Self.hash)","bytes":\#(total)}"#)
        }
        gateway.answers["household-app.avatar.set"] = { request in
            Self.ok(request, #"{"participants":[{"id":"corey","name":"Corey","kind":"assistant","isOwner":false}]}"#)
        }
        try await gateway.connect()
        let room = RoomModel(connection: gateway.connection, sign: { _ in "signature" })
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 2044)

        // Act
        try await room.setFace(of: RoomModel.familyFaceId, jpeg: jpeg, side: 512)

        // Assert
        let named = try XCTUnwrap(gateway.requests("household-app.avatar.set").first?.params)
        XCTAssertEqual(named["participant"]?.stringValue, "family")
        XCTAssertEqual(named["media"]?["id"]?.stringValue, Self.hash)
        XCTAssertEqual(room.familyAvatar?.id, Self.hash)
        XCTAssertNil(room.participant("corey")?.avatar, "the family photo is nobody's own face")
    }
}
