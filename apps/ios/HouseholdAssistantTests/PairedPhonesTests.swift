// Account's iPhones, from the phone's side: the list in the household-app plugin's shape
// with this iPhone first, what the phone signs to remove another or to ask for a setup
// code for a new one, and what shows while each is on its way or refused. Driven over a
// scripted gateway.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class PairedPhonesTests: XCTestCase {
    /// A connected gateway that answers each household-app method from a closure, or holds
    /// a request unanswered while its closure gives nil.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var answers: [String: (GatewayRequest) -> String?] = [:]
        private(set) var signed: [String] = []

        init() {
            let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
            let signer = DeviceSigner(deviceId: "this-iphone", publicKey: "public-key") { _ in "connect-signature" }
            connection = GatewayConnection(transport: transport, credentials: store, signer: signer) { _ in
                await Task.yield()
            }
            transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
            transport.onRequest = { [weak self] transport, request in
                if request.method == "connect" {
                    transport.push((try? Fixtures.text("hello-ok-device-token", answering: request.id)) ?? "")
                } else if let answer = self?.answers[request.method], let text = answer(request) {
                    transport.push(text)
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

    private static func refused(_ request: GatewayRequest, _ message: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"\#(message)"}}"#
    }

    private static let ipad = #"{"id":"franco-ipad","name":"Franco's iPad","model":"ipad","lastSeenAtMs":1759913600000,"isThisPhone":false}"#
    private static let thisIPhone = #"{"id":"this-iphone","name":"Steward AI on iPhone","model":"iphone","lastSeenAtMs":1759999940000,"isThisPhone":true}"#
    private static let oldIPhone = #"{"id":"old-iphone","name":"Steward AI on iPhone","model":null,"lastSeenAtMs":null,"isThisPhone":false}"#

    private static func phones(_ rows: String...) -> String {
        #"{"phones":[\#(rows.joined(separator: ","))]}"#
    }

    private static let code =
        #"{"setupCode":"c2V0dXAtY29kZQ","link":"https://household.example.ts.net:18789/household-app/pair#c2V0dXAtY29kZQ","expiresAtMs":1760000600000}"#

    /// The shared test vector's moment.
    private let clock = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeModel(_ gateway: Gateway) -> PairedPhones {
        PairedPhones(connection: gateway.connection, sign: { gateway.sign($0) }, now: { [unowned self] in self.clock })
    }

    /// A model that has read Franco's three phones, the iPad listed first.
    private func loaded(_ gateway: Gateway) async throws -> PairedPhones {
        gateway.answers["household-app.phones"] = { Self.ok($0, Self.phones(Self.ipad, Self.thisIPhone, Self.oldIPhone)) }
        try await gateway.connect()
        let model = makeModel(gateway)
        await model.refresh()
        XCTAssertEqual(model.phones.count, 3)
        return model
    }

    private func eventually(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var attemptsLeft = 400
        while attemptsLeft > 0, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
    }

    // MARK: - What the phone signs

    func testTheSignedTextsAreTheSharedVectors() {
        let removal = PhoneAction(at: 1_760_000_000_000, kind: .remove(device: "device-2"))
        let pairing = PhoneAction(at: 1_760_000_000_000, kind: .pair)

        XCTAssertEqual(removal.signedText, "household-app/phone/v1\n1760000000000\nremove\ndevice-2")
        XCTAssertEqual(pairing.signedText, "household-app/phone/v1\n1760000000000\npair\n")
        XCTAssertEqual(removal.params(signature: "sig"), .object([
            "at": .number(1_760_000_000_000),
            "device": .string("device-2"),
            "signature": .string("sig"),
        ]))
        XCTAssertEqual(pairing.params(signature: "sig"), .object([
            "at": .number(1_760_000_000_000),
            "signature": .string("sig"),
        ]))
    }

    // MARK: - The list

    func testThePhonesDecodeInTheContractsShapeWithThisIPhoneFirst() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)

        XCTAssertEqual(model.phones.map(\.id), ["this-iphone", "franco-ipad", "old-iphone"])
        XCTAssertEqual(model.phones[1], PairedPhone(
            id: "franco-ipad",
            name: "Franco's iPad",
            model: "ipad",
            lastSeenAtMs: 1_759_913_600_000,
            isThisPhone: false
        ))
        XCTAssertNil(model.phones[2].model)
        XCTAssertNil(model.phones[2].lastSeenAtMs)
        XCTAssertEqual(gateway.requests("household-app.phones").first?.params, .object([:]))
    }

    func testEachPhoneIsNamedByItsModelAndDrawnAsOne() throws {
        let phones = try JSONDecoder().decode([PairedPhone].self, from: Data("[\(Self.ipad),\(Self.thisIPhone),\(Self.oldIPhone)]".utf8))

        XCTAssertEqual(phones.map(\.modelName), ["iPad", "iPhone", "iPhone"])
        XCTAssertEqual(phones.map(\.symbol), ["ipad", "iphone", "iphone"])
        XCTAssertEqual(phones[0].lastSeen, Date(timeIntervalSince1970: 1_759_913_600))
        XCTAssertNil(phones[2].lastSeen)
    }

    func testAListThatCannotBeReadKeepsTheLastOne() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.phones"] = { Self.refused($0, "unknown method: household-app.phones") }

        await model.refresh()

        XCTAssertEqual(model.phones.count, 3)
    }

    // MARK: - Removing one

    func testRemovingAPhoneIsSignedSentAndTheListIsWhatTheGatewayAnswers() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.phones.remove"] = { Self.ok($0, Self.phones(Self.thisIPhone, Self.oldIPhone)) }

        await model.remove(model.phones[1])

        XCTAssertEqual(gateway.signed, ["household-app/phone/v1\n1760000000000\nremove\nfranco-ipad"])
        XCTAssertEqual(gateway.requests("household-app.phones.remove").first?.params, .object([
            "at": .number(1_760_000_000_000),
            "device": .string("franco-ipad"),
            "signature": .string("phone-signature-1"),
        ]))
        XCTAssertEqual(model.phones.map(\.id), ["this-iphone", "old-iphone"])
        XCTAssertNil(model.refusal)
    }

    func testWhileARemovalIsOnItsWayItsRowSaysSo() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        var held: GatewayRequest?
        gateway.answers["household-app.phones.remove"] = { request in
            held = request
            return nil
        }
        let ipad = model.phones[1]

        let removing = Task { await model.remove(ipad) }
        await eventually("sent") { held != nil }

        XCTAssertTrue(model.isRemoving(ipad))
        XCTAssertFalse(model.isRemoving(model.phones[2]))
        gateway.transport.push(Self.ok(try XCTUnwrap(held), Self.phones(Self.thisIPhone)))
        await removing.value
        XCTAssertFalse(model.isRemoving(ipad))
        XCTAssertEqual(model.phones.map(\.id), ["this-iphone"])
    }

    func testARefusedRemovalKeepsThePhoneAndSaysWhy() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.phones.remove"] = { Self.refused($0, "the gateway already has a newer change") }

        await model.remove(model.phones[1])

        XCTAssertEqual(model.phones.count, 3)
        XCTAssertEqual(model.refusal, "the gateway already has a newer change")
        XCTAssertFalse(model.isRemoving(model.phones[1]))

        gateway.answers["household-app.phones.remove"] = { Self.ok($0, Self.phones(Self.thisIPhone, Self.ipad)) }
        await model.remove(model.phones[2])
        XCTAssertNil(model.refusal, "the next removal clears it")
    }

    func testEachSignedActionIsLaterThanTheLastWhenTheClockHasNotMoved() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.phones.remove"] = { Self.ok($0, Self.phones(Self.thisIPhone)) }
        gateway.answers["household-app.pair.code"] = { Self.ok($0, Self.code) }

        await model.remove(model.phones[1])
        await model.askForCode()

        XCTAssertEqual(gateway.signed, [
            "household-app/phone/v1\n1760000000000\nremove\nfranco-ipad",
            "household-app/phone/v1\n1760000000001\npair\n",
        ])
    }

    // MARK: - A code for a new iPhone

    func testANewPhoneCodeIsSignedAndShownWithItsLink() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.pair.code"] = { Self.ok($0, Self.code) }

        await model.askForCode()

        XCTAssertEqual(gateway.signed, ["household-app/phone/v1\n1760000000000\npair\n"])
        XCTAssertEqual(gateway.requests("household-app.pair.code").first?.params, .object([
            "at": .number(1_760_000_000_000),
            "signature": .string("phone-signature-1"),
        ]))
        XCTAssertEqual(model.newPhoneCode, NewPhoneCode(
            setupCode: "c2V0dXAtY29kZQ",
            link: try XCTUnwrap(URL(string: "https://household.example.ts.net:18789/household-app/pair#c2V0dXAtY29kZQ")),
            expiresAtMs: 1_760_000_600_000
        ))
        XCTAssertFalse(model.isAskingForCode)
        XCTAssertNil(model.codeRefusal)
    }

    func testWhileACodeIsOnItsWayThereIsNoneToShow() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.pair.code"] = { Self.ok($0, Self.code) }
        await model.askForCode()
        var held: GatewayRequest?
        gateway.answers["household-app.pair.code"] = { request in
            held = request
            return nil
        }

        let asking = Task { await model.askForCode() }
        await eventually("sent") { held != nil }

        XCTAssertTrue(model.isAskingForCode)
        XCTAssertNil(model.newPhoneCode, "a code already used up is never shown again")
        gateway.transport.push(Self.ok(try XCTUnwrap(held), Self.code))
        await asking.value
        XCTAssertNotNil(model.newPhoneCode)
    }

    func testARefusedCodeSaysWhyAndShowsNone() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.pair.code"] = {
            Self.refused($0, "channels.household.phoneUrl is not set, so phones cannot be told where to connect")
        }

        await model.askForCode()

        XCTAssertNil(model.newPhoneCode)
        XCTAssertEqual(model.codeRefusal, "channels.household.phoneUrl is not set, so phones cannot be told where to connect")
        XCTAssertFalse(model.isAskingForCode)
    }

    func testACodeIsForgottenOnceItsPageClosesAndADifferentGatewaysPhonesAreToo() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.pair.code"] = { Self.ok($0, Self.code) }
        await model.askForCode()

        model.forgetCode()
        XCTAssertNil(model.newPhoneCode)

        await model.askForCode()
        model.reset()
        XCTAssertEqual(model.phones, [])
        XCTAssertNil(model.newPhoneCode)
        XCTAssertNil(model.refusal)
        XCTAssertNil(model.codeRefusal)
    }
}
