// The holding lines a call says while the assistant thinks: spoken once per voice by the
// gateway, kept on the phone, and read back on every call after. Driven over a scripted
// gateway.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class HoldingLinesTests: XCTestCase {
    /// A connected gateway that answers each household-app method from a closure, and
    /// speaks each line as audio named for the line.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var voice = "will"
        /// Lines the gateway refuses to speak, for today's ceiling.
        var refused: Set<String> = []

        init(lines: [String]) {
            let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
            let signer = DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "connect-signature" }
            connection = GatewayConnection(transport: transport, credentials: store, signer: signer) { _ in
                await Task.yield()
            }
            transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
            transport.onRequest = { [weak self] transport, request in
                guard let self else {
                    return
                }
                switch request.method {
                case "connect":
                    transport.push((try? Fixtures.text("hello-ok-device-token", answering: request.id)) ?? "")
                case "household-app.settings":
                    transport.push(Gateway.ok(request, Gateway.settings(voice: self.voice)))
                case "household-app.speak":
                    let text = request.params["text"]?.stringValue ?? ""
                    guard !self.refused.contains(text), let index = lines.firstIndex(of: text) else {
                        transport.push(#"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"LIMIT","message":"Talk has said all it can for today."}}"#)
                        return
                    }
                    transport.push(Gateway.ok(request, #"{"media":{"id":"\#(Gateway.hash(index))","mime":"audio/mpeg","bytes":\#(Gateway.audio(index).count)}}"#))
                case "household-app.media":
                    let id = request.params["id"]?.stringValue ?? ""
                    let bytes = (0..<lines.count).first { Gateway.hash($0) == id }.map(Gateway.audio) ?? Data()
                    transport.push(Gateway.ok(request, #"{"data":"\#(bytes.base64EncodedString())","offset":0,"total":\#(bytes.count)}"#))
                default:
                    break
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

        static func hash(_ index: Int) -> String {
            String(repeating: String(index, radix: 16), count: 64)
        }

        static func audio(_ index: Int) -> Data {
            Data(repeating: UInt8(index + 1), count: 32)
        }

        private static func ok(_ request: GatewayRequest, _ payload: String) -> String {
            #"{"type":"res","id":"\#(request.id)","ok":true,"payload":\#(payload)}"#
        }

        private static func settings(voice: String) -> String {
            #"""
            {"assistant":{"name":"Corey","voice":"\#(voice)","tone":40,"length":"balanced"},
            "voices":[{"id":"will","name":"Will","summary":"Young man, warm and easy"},{"id":"jessica","name":"Jessica","summary":"Young woman, bright and kind"}],
            "model":{"id":"z-ai/glm-5.3-flash","name":"GLM 5.3 Flash","company":"Z.ai","icon":"zai","fallbacks":[]},
            "connectors":[],
            "notifications":{}}
            """#
        }
    }

    private let lines = ["One sec.", "Let me check.", "Just a moment."]
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("holding-lines-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One call's lines, kept where every call on this phone keeps them.
    private func holdingLines(_ gateway: Gateway) -> HoldingLines {
        HoldingLines(
            connection: gateway.connection,
            media: RoomMediaCache(connection: gateway.connection, directory: directory),
            record: directory.appendingPathComponent("holding-lines.json")
        )
    }

    func testEachLineIsSpokenOnceInTheAssistantsVoiceAndReadBackOnTheNextCall() async throws {
        // Arrange
        let gateway = Gateway(lines: lines)
        try await gateway.connect()

        // Act
        let first = holdingLines(gateway)
        await first.prepare(lines)
        let next = holdingLines(gateway)
        await next.prepare(lines)

        // Assert
        XCTAssertEqual(gateway.requests("household-app.speak").compactMap { $0.params["text"]?.stringValue }, lines)
        XCTAssertEqual(gateway.requests("household-app.speak").map { $0.params["voice"] }, [nil, nil, nil], "in the voice the replies are said in")
        for (index, line) in lines.enumerated() {
            let file = try XCTUnwrap(next.file(for: line), line)
            XCTAssertEqual(try Data(contentsOf: file), Gateway.audio(index), line)
            XCTAssertEqual(first.file(for: line), file)
        }
    }

    /// As on Denise's gateway on 17 October, where a call that ended at once and the call
    /// tried again right after asked for 11 speaks of 6 lines between them.
    func testACallThatEndedBeforeItsLinesWereReadySpeaksNoneAndTheNextSpeaksEachOnce() async throws {
        // Arrange
        let gateway = Gateway(lines: lines)
        try await gateway.connect()
        let ended = holdingLines(gateway)
        let preparing = Task {
            await ended.prepare(lines)
        }

        // Act
        preparing.cancel()
        await preparing.value
        let next = holdingLines(gateway)
        await next.prepare(lines)

        // Assert
        XCTAssertEqual(gateway.requests("household-app.settings").count, 1, "the ended call asked nothing")
        XCTAssertEqual(gateway.requests("household-app.speak").compactMap { $0.params["text"]?.stringValue }, lines)
        XCTAssertNil(ended.file(for: "One sec."))
        XCTAssertNotNil(next.file(for: "One sec."))
    }

    func testAVoiceChangedInSettingsSpeaksTheLinesAfresh() async throws {
        let gateway = Gateway(lines: lines)
        try await gateway.connect()
        await holdingLines(gateway).prepare(lines)

        gateway.voice = "jessica"
        await holdingLines(gateway).prepare(lines)

        XCTAssertEqual(gateway.requests("household-app.speak").count, lines.count * 2)
    }

    func testALineThatCannotBeSpokenIsLeftOutAndAskedForAgainNextTime() async throws {
        // Arrange
        let gateway = Gateway(lines: lines)
        gateway.refused = ["Let me check."]
        try await gateway.connect()

        // Act
        let refused = holdingLines(gateway)
        await refused.prepare(lines)

        // Assert: the refusal stops the asking, so the line after it is not asked for.
        XCTAssertNotNil(refused.file(for: "One sec."))
        XCTAssertNil(refused.file(for: "Let me check."))
        XCTAssertNil(refused.file(for: "Just a moment."))
        XCTAssertEqual(gateway.requests("household-app.speak").compactMap { $0.params["text"]?.stringValue }, ["One sec.", "Let me check."])

        gateway.refused = []
        let later = holdingLines(gateway)
        await later.prepare(lines)
        XCTAssertEqual(
            gateway.requests("household-app.speak").compactMap { $0.params["text"]?.stringValue },
            ["One sec.", "Let me check.", "Let me check.", "Just a moment."],
            "only what was never spoken is asked for"
        )
        XCTAssertNotNil(later.file(for: "Just a moment."))
    }

    func testNoVoiceToSpeakInMeansNoLines() async throws {
        let gateway = Gateway(lines: lines)
        try await gateway.connect()
        gateway.transport.onRequest = { transport, request in
            if request.method == "household-app.settings" {
                transport.push(#"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"UNAVAILABLE","message":"the household app channel is not running"}}"#)
            }
        }

        let call = holdingLines(gateway)
        await call.prepare(lines)

        XCTAssertNil(call.file(for: "One sec."))
        XCTAssertTrue(gateway.requests("household-app.speak").isEmpty)
    }
}
