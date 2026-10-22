// Settings and each assistant's page, from the phone's side: what the gateway answers in
// the shape the household-app plugin's contract gives it, what the phone signs to change
// one thing, the row that shows the gateway's read-back, and the spring back when it
// refuses. Driven over a scripted gateway.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class SettingsTests: XCTestCase {
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
            let signer = DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "connect-signature" }
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

    private static func refused(_ request: GatewayRequest, code: String = "INVALID_REQUEST", _ message: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    /// Corey's settings as the contract shapes them, with `tone`, the family room's
    /// notifications, his image and video models and his second and third text models as
    /// given. Without `made` they are the settings of a gateway older than the image and
    /// video models.
    private static func settings(tone: Int = 40, weather: Bool = false, family: String = "mentions", made: String = "", fallbacks: String = SettingsTests.fallbacks) -> String {
        #"""
        {"assistant":{"name":"Corey","voice":"will","tone":\#(tone),"length":"balanced"},
        "voices":[{"id":"will","name":"Will","summary":"Young man, warm and easy"},{"id":"jessica","name":"Jessica","summary":"Young woman, bright and kind"}],
        "model":{"id":"z-ai/glm-5.3-flash","name":"GLM 5.3 Flash","company":"Z.ai","icon":"zai","fallbacks":[\#(fallbacks)]},
        \#(made)"connectors":[{"id":"scripture","name":"SIQsermon","category":"faith","icon":"siqsermon","summary":"Scripture, sermons and word studies","isOn":true,"signIn":null,"accounts":0},{"id":"weather","name":"Weather","category":"everyday","icon":"symbol:cloud.sun.fill","summary":"Forecasts where you are","isOn":\#(weather),"signIn":null,"accounts":0}],
        "notifications":{"family":"\#(family)"}}
        """#
    }

    /// GLM 5.3 second and DeepSeek V4 Flash third, as both gateways start.
    private static let fallbacks = #"{"id":"z-ai/glm-5.3","name":"GLM 5.3","company":"Z.ai","icon":"zai"},{"id":"deepseek/deepseek-v4-flash-0731:free","name":"DeepSeek V4 Flash","company":"DeepSeek","icon":"deepseek"}"#

    private static let models = #"""
        {"models":[
        {"id":"z-ai/glm-5.3-flash","name":"GLM 5.3 Flash","company":"Z.ai","icon":"zai","inputPerMillion":0.1,"outputPerMillion":0.4,"badge":"fast"},
        {"id":"anthropic/claude-sonnet","name":"Claude Sonnet","company":"Anthropic","icon":"anthropic","inputPerMillion":3,"outputPerMillion":15,"badge":"smart"},
        {"id":"meta-llama/llama-4-maverick","name":"Llama 4 Maverick","company":"Meta","icon":"symbol:cpu","inputPerMillion":0.15,"outputPerMillion":0.6,"badge":null},
        {"id":"deepseek/deepseek-v4-flash-0731:free","name":"DeepSeek V4 Flash","company":"DeepSeek","icon":"deepseek","inputPerMillion":0,"outputPerMillion":0,"badge":"free"}
        ]}
        """#

    /// Corey's image and video models as a gateway that has them sends them, ahead of the
    /// connectors: GPT Image 2.5 Flare for pictures, and no video model.
    private static let made = #""imageModel":{"id":"openai/gpt-image-2.5-flare","name":"GPT Image 2.5 Flare","company":"OpenAI","icon":"openai"},"videoModel":null,"#

    /// The same once Nano Banana 2 makes the pictures.
    private static let madeWithNanoBanana = #""imageModel":{"id":"google/gemini-3.1-flash-image","name":"Nano Banana 2","company":"Google","icon":"googlegemini"},"videoModel":null,"#

    /// OpenRouter's image models as the gateway lists them, each with its price a million
    /// image tokens, and one OpenRouter gave no price for.
    private static let imageModels = #"""
        {"models":[
        {"id":"openai/gpt-image-2.5-flare","name":"GPT Image 2.5 Flare","company":"OpenAI","icon":"openai","price":{"dollars":30,"per":"million image tokens"}},
        {"id":"google/gemini-3.1-flash-image","name":"Nano Banana 2","company":"Google","icon":"googlegemini","price":{"dollars":60,"per":"million image tokens"}},
        {"id":"black-forest-labs/flux-3-image","name":"FLUX 3 Image","company":"Black Forest Labs","icon":"symbol:cpu","price":null}
        ]}
        """#

    /// The household's month as the box hands it to every gateway (spend.js).
    private static let spend = #"""
        {"month":"2026-10","at":1792101000000,"total":38.40,"days":[{"day":"2026-10-01","spent":2.31},{"day":"2026-10-02","spent":4.85}],"lines":[{"id":"corey","name":"Corey","amount":24.10},{"id":"denise","name":"Denise","amount":11.85},{"id":"other","name":"Other use of the key","amount":2.45}],"resetsOn":"2026-11-01"}
        """#

    /// The shared test vector's moment.
    private let clock = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeModel(_ gateway: Gateway) -> AssistantSettingsModel {
        AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, now: { [unowned self] in self.clock })
    }

    /// A model that has read Corey's settings.
    private func loaded(_ gateway: Gateway) async throws -> AssistantSettingsModel {
        gateway.answers["household-app.settings"] = { Self.ok($0, Self.settings()) }
        try await gateway.connect()
        let model = makeModel(gateway)
        await model.load()
        XCTAssertNotNil(model.current)
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

    // MARK: - What the gateway answers

    func testTheSettingsDecodeInTheContractsShape() throws {
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings().utf8))

        XCTAssertEqual(settings.assistant, AssistantSettings.Assistant(name: "Corey", voice: "will", tone: 40, length: .balanced))
        XCTAssertEqual(settings.voices.map(\.name), ["Will", "Jessica"])
        XCTAssertEqual(settings.voices.first?.summary, "Young man, warm and easy")
        XCTAssertEqual(settings.model.name, "GLM 5.3 Flash")
        XCTAssertEqual(settings.model.company, "Z.ai")
        XCTAssertEqual(settings.model.icon, "zai")
        XCTAssertEqual(settings.model.fallbacks.map(\.name), ["GLM 5.3", "DeepSeek V4 Flash"])
        XCTAssertEqual(settings.connectors.map(\.id), ["scripture", "weather"])
        XCTAssertEqual(settings.connectors.first?.category, .faith)
        XCTAssertEqual(settings.connectors.last?.category, .everyday)
        XCTAssertEqual(settings.connectors.map(\.isOn), [true, false])
    }

    func testTheImageAndVideoModelsDecodeAndAnOlderGatewaysSettingsStillDo() throws {
        // Act
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings(made: Self.made).utf8))
        let older = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings().utf8))

        // Assert
        XCTAssertEqual(settings.imageModel, ModelChoice(id: "openai/gpt-image-2.5-flare", name: "GPT Image 2.5 Flare", company: "OpenAI", icon: "openai"))
        XCTAssertNil(settings.videoModel, "no video model to use")
        XCTAssertNil(older.imageModel, "a gateway older than them sends neither")
        XCTAssertNil(older.videoModel)
        XCTAssertEqual(older.model.name, "GLM 5.3 Flash")
    }

    func testVisionSelectionDecodesAndOlderGatewaysRemainCompatible() throws {
        let vision = #""visionModel":{"id":"acme/vision","name":"Vision","company":"Acme","icon":"symbol:eye"},"#
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings(made: vision + Self.made).utf8))
        XCTAssertEqual(settings.visionModel?.id, "acme/vision")
        let older = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings().utf8))
        XCTAssertNil(older.visionModel)
    }

    func testEveryCategoryAndLengthTheContractNamesDecodes() throws {
        let categories = ["money", "faith", "calendar-and-mail", "notes", "web", "pictures-and-video", "everyday"]
        let decoded = try categories.map { try JSONDecoder().decode(ConnectorCategory.self, from: Data("\"\($0)\"".utf8)) }

        XCTAssertEqual(decoded, ConnectorCategory.allCases)
        XCTAssertEqual(ConnectorCategory.calendarAndMail.title, "Calendar and mail")
        XCTAssertEqual(ConnectorCategory.web.title, "The web")
        XCTAssertEqual(AnswerLength.allCases.map(\.rawValue), ["short", "balanced", "detailed"])
        XCTAssertEqual(AnswerLength.balanced.label, "Balanced")
        XCTAssertEqual(NotificationChoice.allCases.map(\.rawValue), ["all", "mentions", "off"])
    }

    func testANotificationChoiceIsThisPhonesOwnAndAConversationNotListedIsAll() throws {
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings().utf8))

        XCTAssertEqual(settings.notificationChoice(in: .family), .mentions)
        XCTAssertEqual(settings.notificationChoice(in: .direct), .all)
    }

    func testEachReadAsksOnlyForTheConnectorsThisGatewayHas() async throws {
        let gateway = Gateway()
        _ = try await loaded(gateway)

        XCTAssertEqual(gateway.requests("household-app.settings").first?.params, .object([:]))
    }

    func testTheModelsListDecodesWithPricesAndBadges() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.models"] = { Self.ok($0, Self.models) }
        try await gateway.connect()

        let models = try await gateway.connection.openRouterModels()

        XCTAssertEqual(models.map(\.name), ["GLM 5.3 Flash", "Claude Sonnet", "Llama 4 Maverick", "DeepSeek V4 Flash"])
        XCTAssertEqual(models[0].inputPerMillion, 0.1)
        XCTAssertEqual(models[1].outputPerMillion, 15)
        XCTAssertEqual(models.map(\.badge), [.fast, .smart, nil, .free])
        XCTAssertEqual(gateway.requests("household-app.models").first?.params, .object([:]))
    }

    func testEachKindsModelsAreAskedForByKindAndDecodeByNameAndCompany() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.models"] = { request in
            switch request.params["kind"]?.stringValue {
            case "image":
                return Self.ok(request, Self.imageModels)
            case "video":
                return Self.ok(request, #"{"models":[]}"#)
            default:
                return Self.ok(request, Self.models)
            }
        }
        try await gateway.connect()

        // Act
        let images = try await gateway.connection.modelChoices(.image)
        let videos = try await gateway.connection.modelChoices(.video)
        let texts = try await gateway.connection.modelChoices(.text)

        // Assert
        XCTAssertEqual(images.map(\.name), ["GPT Image 2.5 Flare", "Nano Banana 2", "FLUX 3 Image"])
        XCTAssertEqual(images.map(\.company), ["OpenAI", "Google", "Black Forest Labs"])
        XCTAssertEqual(images.last?.icon, "symbol:cpu")
        XCTAssertEqual(images.first?.price, MediaModel.Price(dollars: 30, per: "million image tokens"))
        XCTAssertNil(images.last?.price, "OpenRouter gave no price, and none is made up")
        XCTAssertNil(texts.first?.price, "a list without prices still reads")
        XCTAssertTrue(videos.isEmpty, "OpenRouter may offer no video model")
        XCTAssertEqual(texts.first?.name, "GLM 5.3 Flash", "the text list reads by name and company too")
        XCTAssertEqual(gateway.requests("household-app.models").map(\.params), [
            .object(["kind": .string("image")]),
            .object(["kind": .string("video")]),
            .object(["kind": .string("text")]),
        ])
    }

    func testAMissingModelsListIsAnUnexpectedAnswer() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.models"] = { Self.ok($0, #"{"images":[]}"#) }
        try await gateway.connect()

        // Act and Assert
        do {
            _ = try await gateway.connection.modelChoices(.image)
            XCTFail("an answer without models gave a list")
        } catch let error as GatewayConnectionError {
            XCTAssertEqual(error, .unexpectedFrame)
        }
    }

    func testSpendIsTheHouseholdsMonthAsTheBoxAddedItUp() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.spend"] = { Self.ok($0, Self.spend) }
        try await gateway.connect()

        // Act
        let spend = try await gateway.connection.spend()

        // Assert
        XCTAssertEqual(spend.total, 38.40)
        XCTAssertEqual(spend.days.map(\.day), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(spend.days.map(\.spent), [2.31, 4.85])
        XCTAssertEqual(spend.lines.map(\.id), ["corey", "denise", "other"])
        XCTAssertEqual(spend.lines.map(\.amount), [24.10, 11.85, 2.45])
        XCTAssertEqual(spend.at, 1_792_101_000_000)
        XCTAssertEqual(spend.monthName, "October")
        XCTAssertEqual(spend.resetsOnWords, "November 1")
        XCTAssertEqual(gateway.requests("household-app.spend").count, 1)
        XCTAssertTrue(gateway.requests("usage.cost").isEmpty, "the box adds the month up, not the phone")
    }

    func testSpendFailsBeforeTheBoxHasAddedUpTheMonth() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.spend"] = { Self.refused($0, "The box has not added up this month's spend yet") }
        try await gateway.connect()

        // Act and Assert
        do {
            _ = try await gateway.connection.spend()
            XCTFail("a month the box has not added up gave a spend report")
        } catch {}
    }

    func testTheLastMonthOpensAtOnceAndTheNewerOneIsKeptForNextTime() async throws {
        // Arrange
        let gateway = Gateway()
        let store = SpendMemory()
        store.spendReport = SpendReport(month: "2026-10", at: 1, total: 1.00, days: [], lines: [SpendReport.Line(id: "other", name: "Other use of the key", amount: 1.00)], resetsOn: "2026-11-01")
        gateway.answers["household-app.spend"] = { Self.ok($0, Self.spend) }
        try await gateway.connect()

        // Act
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, spendStore: store)
        let opened = model.spend?.total
        await model.loadSpend()

        // Assert
        XCTAssertEqual(opened, 1.00, "the page opens on the last month before the gateway answers")
        XCTAssertEqual(model.spend?.total, 38.40)
        XCTAssertEqual(store.spendReport, model.spend)
    }

    func testAMonthTheGatewayCannotGiveKeepsTheLastOne() async throws {
        // Arrange
        let gateway = Gateway()
        let store = SpendMemory()
        gateway.answers["household-app.spend"] = { Self.ok($0, Self.spend) }
        try await gateway.connect()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, spendStore: store)
        await model.loadSpend()

        // Act
        gateway.answers["household-app.spend"] = { Self.refused($0, "The box has not added up this month's spend yet") }
        await model.loadSpend()

        // Assert
        XCTAssertEqual(model.spend?.total, 38.40)
        XCTAssertEqual(store.spendReport?.total, 38.40)
        XCTAssertNotNil(model.spendErrorText, "cached spend must not hide the refresh failure")
        XCTAssertFalse(model.isLoadingSpend)
    }

    func testSpendPollingRetriesAFailureAndClearsTheErrorWhenItRecovers() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.spend"] = { Self.refused($0, "Temporarily unavailable") }
        try await gateway.connect()
        let model = makeModel(gateway)
        var waits = 0

        await model.watchSpend { seconds in
            XCTAssertEqual(seconds, 60)
            waits += 1
            if waits == 1 {
                XCTAssertNotNil(model.spendErrorText)
                gateway.answers["household-app.spend"] = { Self.ok($0, Self.spend) }
            } else {
                throw CancellationError()
            }
        }

        XCTAssertEqual(gateway.requests("household-app.spend").count, 2)
        XCTAssertEqual(model.spend?.total, 38.40)
        XCTAssertNil(model.spendErrorText)
        XCTAssertFalse(model.isLoadingSpend)
    }

    func testSpendPollingUpdatesTheGraphTotalAndRowsFromTheSameSnapshot() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.spend"] = { Self.ok($0, Self.spend) }
        try await gateway.connect()
        let store = SpendMemory()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, spendStore: store)
        let newer = Self.spend
            .replacingOccurrences(of: "1792101000000", with: "1792101600000")
            .replacingOccurrences(of: "38.40", with: "40.40")
            .replacingOccurrences(of: "4.85", with: "40.40")
            .replacingOccurrences(of: "2.45", with: "4.45")
        var waits = 0

        await model.watchSpend { _ in
            waits += 1
            if waits == 1 {
                XCTAssertEqual(model.spend?.total, 38.40)
                gateway.answers["household-app.spend"] = { Self.ok($0, newer) }
            } else {
                throw CancellationError()
            }
        }

        let report = try XCTUnwrap(model.spend)
        XCTAssertEqual(report.total, 40.40)
        XCTAssertEqual(report.days.last?.spent, report.total)
        XCTAssertEqual(report.lines.map(\.amount).reduce(0, +), report.total, accuracy: 0.001)
        XCTAssertEqual(store.spendReport, report)
        XCTAssertEqual(SpendMonth(report)?.point("2026-10-02")?.spent, report.total)
    }

    func testAnOlderGatewayReportCannotRollBackTheSavedSpend() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.spend"] = { Self.ok($0, Self.spend) }
        try await gateway.connect()
        let store = SpendMemory()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, spendStore: store)
        await model.loadSpend()
        let current = model.spend
        let older = Self.spend.replacingOccurrences(of: "1792101000000", with: "1792100000000")
        gateway.answers["household-app.spend"] = { Self.ok($0, older) }

        await model.loadSpend()

        XCTAssertEqual(model.spend, current)
        XCTAssertEqual(store.spendReport, current)
        XCTAssertNotNil(model.spendErrorText)
    }

    func testOverlappingSpendRefreshesSendOnlyOneRequest() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let model = makeModel(gateway)
        let first = Task { await model.loadSpend() }
        await eventually("spend request") { gateway.requests("household-app.spend").count == 1 }
        XCTAssertTrue(model.isLoadingSpend)

        await model.loadSpend()

        XCTAssertEqual(gateway.requests("household-app.spend").count, 1)
        let request = try XCTUnwrap(gateway.requests("household-app.spend").first)
        gateway.transport.push(Self.ok(request, Self.spend))
        await first.value
        XCTAssertEqual(model.spend?.total, 38.40)
        XCTAssertFalse(model.isLoadingSpend)
    }

    func testAResponseAfterResetCannotRestoreThePreviousHouseholdsSpend() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let store = SpendMemory()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, spendStore: store)
        let first = Task { await model.loadSpend() }
        await eventually("spend request") { gateway.requests("household-app.spend").count == 1 }
        let request = try XCTUnwrap(gateway.requests("household-app.spend").first)

        model.reset()
        gateway.transport.push(Self.ok(request, Self.spend))
        await first.value

        XCTAssertNil(model.spend)
        XCTAssertNil(store.spendReport)
        XCTAssertFalse(model.isLoadingSpend)
    }

    func testCancelledSpendPollingStopsWithoutAnotherRequest() async throws {
        let gateway = Gateway()
        try await gateway.connect()
        let model = makeModel(gateway)
        let watch = Task { await model.watchSpend() }
        await eventually("spend request") { gateway.requests("household-app.spend").count == 1 }
        let request = try XCTUnwrap(gateway.requests("household-app.spend").first)

        watch.cancel()
        gateway.transport.push(Self.ok(request, Self.spend))
        await watch.value

        XCTAssertEqual(gateway.requests("household-app.spend").count, 1)
        XCTAssertNil(model.spend, "a cancelled read must not publish its late answer")
        XCTAssertFalse(model.isLoadingSpend)
    }

    /// The phone's settings, as far as the Spend page keeps anything in them.
    private final class SpendMemory: SpendStore {
        var spendReport: SpendReport?
    }

    func testTheSyncPageCarriesTheOtherAssistantAndTheRoomKeepsIt() async throws {
        let gateway = Gateway()
        let peer = #""peerAssistant":{"name":"Denise","voiceName":"Jessica","voice":"jessica","modelName":"GLM 5.3 Flash","familyRoom":"Answers when named"}"#
        let page = #"{"entries":[],"rev":3,"hasMore":false,"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{},\#(peer)}"#
        let history = #"{"messages":[],"hasMore":false,"reactions":{},"reads":[],"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{}}"#
        gateway.answers["household-app.history"] = { Self.ok($0, history) }
        gateway.answers["household-app.sync"] = { Self.ok($0, page) }
        try await gateway.connect()
        let room = RoomModel(connection: gateway.connection, sign: { gateway.sign($0) })

        await room.refresh()

        let expected = PeerAssistant(name: "Denise", voiceName: "Jessica", voice: "jessica", modelName: "GLM 5.3 Flash", familyRoom: "Answers when named")
        XCTAssertEqual(room.peerAssistant, expected)
        let older = #"{"entries":[],"rev":3,"hasMore":false,"participants":[],"self":{"person":"franco","assistant":"corey"},"sessionKeys":{}}"#
        XCTAssertNil(try JSONDecoder().decode(RoomSyncPage.self, from: Data(older.utf8)).peerAssistant, "a gateway without it still syncs")
        room.reset()
        XCTAssertNil(room.peerAssistant)
    }

    // MARK: - What the phone signs

    func testTheSignedTextIsTheSharedVector() {
        let change = SettingsChange(at: 1_760_000_000_000, field: .tone, value: "40")

        XCTAssertEqual(change.signedText, "household-app/settings/v1\n1760000000000\ntone\n40")
        XCTAssertEqual(change.params(signature: "sig"), .object([
            "at": .number(1_760_000_000_000),
            "field": .string("tone"),
            "value": .string("40"),
            "signature": .string("sig"),
        ]))
    }

    func testEachFieldIsSpelledAsTheContractSpellsIt() {
        let fields: [(SettingsField, String)] = [
            (.name, "name"),
            (.voice, "voice"),
            (.tone, "tone"),
            (.length, "length"),
            (.model, "model"),
            (.fallbackModel(1), "model.fallback.1"),
            (.fallbackModel(2), "model.fallback.2"),
            (.visionModel, "model.vision"),
            (.imageModel, "model.image"),
            (.videoModel, "model.video"),
            (.connector("scripture"), "connector.scripture"),
            (.notifications(.family), "notifications.family"),
            (.notifications(.direct), "notifications.direct"),
        ]
        for (field, key) in fields {
            XCTAssertEqual(field.key, key)
        }
    }

    func testEachKindOfModelIsChangedByItsOwnSignedField() {
        let cases: [(kind: ModelKind, field: String, id: String)] = [
            (.text, "model", "z-ai/glm-5.3"),
            (.vision, "model.vision", "google/gemini-flash"),
            (.image, "model.image", "google/gemini-3.1-flash-image"),
            (.video, "model.video", "google/veo-3.1-fast"),
        ]
        for (kind, field, id) in cases {
            let change = SettingsChange(at: 1_760_000_000_000, field: kind.field, value: id)

            XCTAssertEqual(change.signedText, "household-app/settings/v1\n1760000000000\n\(field)\n\(id)", kind.label)
            XCTAssertEqual(change.params(signature: "sig")["field"], .string(field), kind.label)
        }
        XCTAssertEqual(ModelKind.allCases.map(\.label), ["Text", "Vision", "Image", "Video"])
    }

    // MARK: - Changing one thing

    func testAChangeIsSignedSentAndTheRowShowsWhatTheGatewayReadBack() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.settings.change"] = { Self.ok($0, Self.settings(tone: 40)) }
        await model.change(.tone, to: "64")
        XCTAssertEqual(model.tone, 40, "the row shows what the gateway holds, not what was asked")

        gateway.answers["household-app.settings.change"] = { Self.ok($0, Self.settings(tone: 64)) }
        await model.change(.tone, to: "64")

        XCTAssertEqual(gateway.signed.first, "household-app/settings/v1\n1760000000000\ntone\n64")
        XCTAssertEqual(gateway.signed.last, "household-app/settings/v1\n1760000000001\ntone\n64", "each change is later than the last")
        XCTAssertEqual(gateway.requests("household-app.settings.change").last?.params, .object([
            "at": .number(1_760_000_000_001),
            "field": .string("tone"),
            "value": .string("64"),
            "signature": .string("phone-signature-2"),
        ]), "nothing beside the signed change, so the connectors this gateway cannot have stay off the list")
        XCTAssertEqual(model.tone, 64)
        XCTAssertFalse(model.isPending(.tone))
        XCTAssertNil(model.refusal)
    }

    func testWhileAChangeIsInFlightTheRowShowsItWithASpinner() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        var held: GatewayRequest?
        gateway.answers["household-app.settings.change"] = { request in
            held = request
            return nil
        }

        let changing = Task { await model.change(.connector("weather"), to: "on") }
        await eventually("sent") { held != nil }
        let weather = try XCTUnwrap(model.current?.connectors.last)

        XCTAssertTrue(model.isPending(.connector("weather")))
        XCTAssertTrue(model.isOn(weather), "the switch shows the new value while it goes")
        XCTAssertEqual(model.connectorsOn, 2)

        gateway.transport.push(Self.ok(try XCTUnwrap(held), Self.settings(weather: true)))
        await changing.value

        XCTAssertFalse(model.isPending(.connector("weather")))
        XCTAssertEqual(model.current?.connectors.last?.isOn, true)
    }

    func testARefusalSpringsBackAndSaysWhyInOnePlainLine() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.settings.change"] = { Self.refused($0, "Only Franco's iPhone can change Corey.") }

        await model.change(.length, to: "detailed")

        XCTAssertEqual(model.length, .balanced, "springs back to what the gateway holds")
        XCTAssertFalse(model.isPending(.length))
        XCTAssertEqual(model.refusal, SettingsRefusal(field: .length, reason: "Only Franco's iPhone can change Corey."))
        XCTAssertEqual(model.refusal(for: [.length, .name]), "Only Franco's iPhone can change Corey.")
        XCTAssertNil(model.refusal(for: [.tone]))

        gateway.answers["household-app.settings.change"] = { Self.ok($0, Self.settings()) }
        await model.change(.length, to: "balanced")
        XCTAssertNil(model.refusal, "the next change clears it")
    }

    func testANotificationChoiceGoesAsThisPhonesOwnField() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.settings.change"] = { Self.ok($0, Self.settings(family: "off")) }

        XCTAssertEqual(model.notificationChoice(in: .family), .mentions)
        XCTAssertEqual(model.notificationChoice(in: .direct), .all)
        await model.change(.notifications(.family), to: NotificationChoice.off.rawValue)

        XCTAssertEqual(gateway.signed, ["household-app/settings/v1\n1760000000000\nnotifications.family\noff"])
        XCTAssertEqual(model.notificationChoice(in: .family), .off)
    }

    func testSettingsThatCannotBeReadSayWhyAndADifferentGatewaysAreForgotten() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.settings"] = { Self.refused($0, "unknown method: household-app.settings") }
        try await gateway.connect()
        let model = makeModel(gateway)

        await model.load()
        XCTAssertNil(model.current)
        XCTAssertEqual(model.errorText, "unknown method: household-app.settings")

        gateway.answers["household-app.settings"] = { Self.ok($0, Self.settings()) }
        gateway.answers["household-app.spend"] = { Self.ok($0, Self.spend) }
        gateway.answers["household-app.models"] = { Self.ok($0, Self.models) }
        await model.load()
        await model.loadSpend()
        await model.loadModels()
        XCTAssertNil(model.errorText)
        model.reset()

        XCTAssertNil(model.current)
        XCTAssertNil(model.spend)
        XCTAssertTrue(model.models.isEmpty)
    }

    // MARK: - The model picker

    func testPopularIsTheBadgedModelsNotInUseAndSearchFindsAnyByNameOrCompany() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.models"] = { Self.ok($0, Self.models) }
        await model.loadModels()

        XCTAssertEqual(model.popularModels.map(\.name), ["Claude Sonnet", "DeepSeek V4 Flash"])
        XCTAssertEqual(model.models(matching: "meta").map(\.name), ["Llama 4 Maverick"])
        XCTAssertEqual(model.models(matching: "flash deep").map(\.name), ["DeepSeek V4 Flash"])
        XCTAssertEqual(model.models(matching: "  ").map(\.name), model.popularModels.map(\.name))
        XCTAssertEqual(model.inUse?.badge, .fast, "the model in use is found in the list for its price and badge")
    }

    func testAThirdModelIsSignedAndItsRowShowsWhatTheGatewayReadBack() async throws {
        // Arrange
        let gateway = Gateway()
        let model = try await loaded(gateway)
        var held: GatewayRequest?
        gateway.answers["household-app.settings.change"] = { request in
            held = request
            return nil
        }
        let claude = #"{"id":"anthropic/claude-sonnet","name":"Claude Sonnet","company":"Anthropic","icon":"anthropic"}"#

        // Act
        let changing = Task { await model.change(.fallbackModel(2), to: "anthropic/claude-sonnet") }
        await eventually("sent") { held != nil }
        let whileGoing = model.fallbackID(2)
        let glm = #"{"id":"z-ai/glm-5.3","name":"GLM 5.3","company":"Z.ai","icon":"zai"}"#
        gateway.transport.push(Self.ok(try XCTUnwrap(held), Self.settings(fallbacks: glm + "," + claude)))
        await changing.value

        // Assert
        XCTAssertEqual(whileGoing, "anthropic/claude-sonnet", "its row shows the pick while it goes")
        XCTAssertEqual(gateway.signed, ["household-app/settings/v1\n1760000000000\nmodel.fallback.2\nanthropic/claude-sonnet"])
        XCTAssertEqual(model.current?.model.fallbacks.map(\.name), ["GLM 5.3", "Claude Sonnet"])
        XCTAssertEqual(model.fallbackID(1), "z-ai/glm-5.3")
        XCTAssertEqual(model.fallbackID(2), "anthropic/claude-sonnet")
        XCTAssertEqual(model.current?.model.name, "GLM 5.3 Flash", "the first model is untouched")
        XCTAssertFalse(model.isPending(.fallbackModel(2)))
    }

    func testClearingTheSecondModelSendsNoModelAndTheThirdMovesUp() async throws {
        // Arrange
        let gateway = Gateway()
        let model = try await loaded(gateway)
        let deepseek = #"{"id":"deepseek/deepseek-v4-flash-0731:free","name":"DeepSeek V4 Flash","company":"DeepSeek","icon":"deepseek"}"#
        gateway.answers["household-app.settings.change"] = { Self.ok($0, Self.settings(fallbacks: deepseek)) }

        // Act
        await model.change(.fallbackModel(1), to: "")

        // Assert
        XCTAssertEqual(gateway.signed, ["household-app/settings/v1\n1760000000000\nmodel.fallback.1\n"])
        XCTAssertEqual(gateway.requests("household-app.settings.change").first?.params["value"], .string(""))
        XCTAssertEqual(model.fallbackID(1), "deepseek/deepseek-v4-flash-0731:free")
        XCTAssertNil(model.fallbackID(2))
    }

    func testABackupIsPickedFromModelsTheChainDoesNotAlreadyHoldElsewhere() async throws {
        // Arrange
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.models"] = { Self.ok($0, Self.models) }

        // Act
        await model.loadModels()

        // Assert: the first model is GLM 5.3 Flash, the second GLM 5.3, the third DeepSeek.
        XCTAssertEqual(model.fallbackChoices(1, matching: "").map(\.name), ["Claude Sonnet"])
        XCTAssertEqual(model.fallbackChoices(2, matching: "flash").map(\.name), ["DeepSeek V4 Flash"])
        XCTAssertEqual(model.fallbackChoices(1, matching: "flash").map(\.name), [])
        XCTAssertEqual(model.fallbackChoices(2, matching: "meta").map(\.name), ["Llama 4 Maverick"])
    }

    func testAnImageModelIsChangedLikeTheChatModelAndTheRowShowsWhatTheGatewayReadBack() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.settings"] = { Self.ok($0, Self.settings(made: Self.made)) }
        try await gateway.connect()
        let model = makeModel(gateway)
        await model.load()
        var held: GatewayRequest?
        gateway.answers["household-app.settings.change"] = { request in
            held = request
            return nil
        }

        // Act
        let changing = Task { await model.change(.imageModel, to: "google/gemini-3.1-flash-image") }
        await eventually("sent") { held != nil }
        let whileGoing = model.pending[.imageModel]
        gateway.transport.push(Self.ok(try XCTUnwrap(held), Self.settings(made: Self.madeWithNanoBanana)))
        await changing.value

        // Assert
        XCTAssertEqual(whileGoing, "google/gemini-3.1-flash-image", "its row has a spinner while it goes")
        XCTAssertEqual(gateway.signed, ["household-app/settings/v1\n1760000000000\nmodel.image\ngoogle/gemini-3.1-flash-image"])
        XCTAssertEqual(model.current?.imageModel?.name, "Nano Banana 2")
        XCTAssertEqual(model.current?.model.name, "GLM 5.3 Flash", "the chat model is untouched")
        XCTAssertFalse(model.isPending(.imageModel))
    }

    func testARefusedVideoModelSpringsBackAndSaysWhyUnderItsOwnGroup() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.settings"] = { Self.ok($0, Self.settings(made: Self.made)) }
        try await gateway.connect()
        let model = makeModel(gateway)
        await model.load()
        gateway.answers["household-app.settings.change"] = { Self.refused($0, "That is not a video model on OpenRouter.") }

        // Act
        await model.change(.videoModel, to: "openai/gpt-image-2.5-flare")

        // Assert
        XCTAssertNil(model.current?.videoModel, "springs back to what the gateway holds")
        XCTAssertEqual(model.refusal(for: [ModelKind.video.field]), "That is not a video model on OpenRouter.")
        XCTAssertNil(model.refusal(for: [ModelKind.image.field]))
        XCTAssertNil(model.refusal(for: [.model]))
    }

    // MARK: - The image and video lists

    func testAListIsReadOnceWhenItsSegmentShowsAndKept() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.models"] = { Self.ok($0, Self.imageModels) }
        try await gateway.connect()
        let lists = ModelLists()

        // Act
        await lists.load(.image, from: gateway.connection)
        await lists.load(.image, from: gateway.connection)

        // Assert
        guard case .read(let images)? = lists.status[.image] else {
            return XCTFail("the image list was not read: \(String(describing: lists.status[.image]))")
        }
        XCTAssertEqual(images.map(\.id), ["openai/gpt-image-2.5-flare", "google/gemini-3.1-flash-image", "black-forest-labs/flux-3-image"])
        XCTAssertEqual(gateway.requests("household-app.models").count, 1, "kept for the page's life")
        XCTAssertNil(lists.status[.video], "a segment never shown is never read")
    }

    func testAListThatCannotBeReadSaysWhyAndIsReadAgainWhenAsked() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.models"] = { Self.refused($0, "OpenRouter did not answer.") }
        try await gateway.connect()
        let lists = ModelLists()

        // Act
        await lists.load(.video, from: gateway.connection)
        let failed = lists.status[.video]
        gateway.answers["household-app.models"] = { Self.ok($0, #"{"models":[]}"#) }
        await lists.load(.video, from: gateway.connection)

        // Assert
        XCTAssertEqual(failed, .failed("OpenRouter did not answer."))
        XCTAssertEqual(lists.status[.video], .read([]), "an empty video list is read, not a failure")
        XCTAssertEqual(gateway.requests("household-app.models").count, 2)
    }

    func testAListLeavesOutTheOneInUseAndSearchFindsAnyByNameCompanyOrId() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.models"] = { Self.ok($0, Self.imageModels) }
        try await gateway.connect()
        let lists = ModelLists()
        await lists.load(.image, from: gateway.connection)
        let inUse = "openai/gpt-image-2.5-flare"

        // Act and Assert
        XCTAssertEqual(lists.models(.image, matching: "", inUse: inUse).map(\.name), ["Nano Banana 2", "FLUX 3 Image"])
        XCTAssertEqual(lists.models(.image, matching: "  ", inUse: nil).count, 3)
        XCTAssertEqual(lists.models(.image, matching: "black forest", inUse: inUse).map(\.name), ["FLUX 3 Image"])
        XCTAssertEqual(lists.models(.image, matching: "gemini", inUse: inUse).map(\.name), ["Nano Banana 2"])
        XCTAssertEqual(lists.models(.image, matching: "gpt", inUse: inUse).map(\.name), ["GPT Image 2.5 Flare"], "a search shows the one in use too")
        XCTAssertTrue(lists.models(.video, matching: "", inUse: nil).isEmpty, "nothing before it is read")
    }

    func testTheOneInUseTakesItsPriceFromItsList() async throws {
        // Arrange
        let gateway = Gateway()
        gateway.answers["household-app.models"] = { Self.ok($0, Self.imageModels) }
        try await gateway.connect()
        let lists = ModelLists()
        let inUse = "openai/gpt-image-2.5-flare"
        let before = lists.listed(.image, id: inUse)

        // Act
        await lists.load(.image, from: gateway.connection)

        // Assert
        XCTAssertNil(before, "no price before the list is read")
        XCTAssertEqual(lists.listed(.image, id: inUse)?.price?.dollars, 30)
        XCTAssertNil(lists.listed(.image, id: "acme/not-listed"))
        XCTAssertNil(lists.listed(.video, id: inUse), "each kind has its own list")
    }

    func testAnImageOrVideoModelsPriceReadsInTheUnitOpenRouterBillsItBy() {
        let cases: [(price: MediaModel.Price?, company: String, line: String)] = [
            (MediaModel.Price(dollars: 30, per: "million image tokens"), "OpenAI", "OpenAI, $30 per million image tokens"),
            (MediaModel.Price(dollars: 9.8204, per: "million image tokens"), "Black Forest Labs", "Black Forest Labs, $9.82 per million image tokens"),
            (MediaModel.Price(dollars: 0.1, per: "second at 720p"), "Google", "Google, $0.10 per second at 720p"),
            (MediaModel.Price(dollars: 0.0988, per: "second at 720p"), "Alibaba", "Alibaba, $0.099 per second at 720p"),
            (MediaModel.Price(dollars: 0.0817, per: "second"), "MiniMax", "MiniMax, $0.082 per second"),
            (MediaModel.Price(dollars: 4.2, per: "million video tokens"), "ByteDance", "ByteDance, $4.20 per million video tokens"),
            (MediaModel.Price(dollars: 0, per: "million image tokens"), "Acme", "Acme, free"),
            (nil, "Acme", "Acme, no price on OpenRouter"),
        ]
        for (price, company, line) in cases {
            let model = MediaModel(id: "x/y", name: "Y", company: company, icon: "symbol:cpu", price: price)

            XCTAssertEqual(ModelPrices.line(model, company: company), line)
        }
        XCTAssertEqual(ModelPrices.line(nil as MediaModel?, company: "OpenAI"), "OpenAI", "just the company until the list is read")
    }

    // MARK: - Speaking a sample

    func testASampleIsSpokenByTheGatewayAndReadAsMedia() async throws {
        let gateway = Gateway()
        let hash = String(repeating: "ab", count: 32)
        gateway.answers["household-app.speak"] = { request in
            request.params["voice"]?.stringValue == "jessica"
                ? Self.ok(request, #"{"media":{"id":"\#(hash)","mime":"audio/mpeg","bytes":4096}}"#)
                : Self.refused(request, code: "LIMIT", "Talk has said all it can for today.")
        }
        try await gateway.connect()

        let sample = try await gateway.connection.speak("Hi, I'm Denise.", voice: "jessica")

        XCTAssertEqual(sample, RoomMedia(id: hash, kind: .voice, mime: "audio/mpeg", bytes: 4096))
        XCTAssertEqual(gateway.requests("household-app.speak").first?.params, .object([
            "text": .string("Hi, I'm Denise."),
            "voice": .string("jessica"),
        ]))
        do {
            _ = try await gateway.connection.speak("Hi", voice: "will")
            XCTFail("expected the ceiling")
        } catch let error as GatewayErrorShape {
            XCTAssertEqual(error.code, "LIMIT")
            XCTAssertEqual(ErrorText.describe(error), "Talk has said all it can for today.")
        }
    }

    func testEachSampleIsSpokenOnceAndAThrottledOneSaysWhy() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        let hash = String(repeating: "cd", count: 32)
        gateway.answers["household-app.speak"] = { Self.ok($0, #"{"media":{"id":"\#(hash)","mime":"audio/mpeg","bytes":2048}}"#) }

        let first = await model.sample("Hi, I'm Corey.", voice: "will")
        let again = await model.sample("Hi, I'm Corey.", voice: "will")

        XCTAssertEqual(first?.id, hash)
        XCTAssertEqual(again, first)
        XCTAssertEqual(model.spokenSample("Hi, I'm Corey.", voice: "will"), first)
        XCTAssertEqual(gateway.requests("household-app.speak").count, 1, "the ceiling counts every character, so a sample is spoken once")

        gateway.answers["household-app.speak"] = { Self.refused($0, code: "LIMIT", "Talk has said all it can for today.") }
        let throttled = await model.sample("Hi, I'm Corey.", voice: "jessica")
        XCTAssertNil(throttled)
        XCTAssertEqual(model.sampleRefusal, "Talk has said all it can for today.")
        model.reset()
        XCTAssertNil(model.spokenSample("Hi, I'm Corey.", voice: "will"))
        XCTAssertNil(model.sampleRefusal)
    }

    // MARK: - Small rules

    func testANameIsOneToTwentyFourLettersSpacesHyphensAndApostrophes() {
        let cases: [(String, Bool)] = [
            ("Corey", true),
            ("Mary-Jo", true),
            ("D'Angelo", true),
            ("Zo\u{EB}", true),
            ("", false),
            ("   ", false),
            ("Corey 2", false),
            ("Corey\nDenise", false),
            (String(repeating: "a", count: 24), true),
            (String(repeating: "a", count: 25), false),
        ]
        for (name, isValid) in cases {
            XCTAssertEqual(AssistantName.isValid(AssistantName.cleaned(name)), isValid, name)
        }
        XCTAssertEqual(AssistantName.cleaned("  D\u{2019}Angelo "), "D'Angelo", "the keyboard's curly apostrophe becomes a plain one")
    }

    func testPricesAndAmountsReadAsDollars() {
        XCTAssertEqual(Dollars.price(0.1), "$0.10")
        XCTAssertEqual(Dollars.price(3), "$3")
        XCTAssertEqual(Dollars.price(2.5), "$2.50")
        XCTAssertEqual(Dollars.price(0.075), "$0.075")
        XCTAssertEqual(Dollars.amount(38.4), "$38.40")
        XCTAssertEqual(Dollars.amount(3.1), "$3.10")
        XCTAssertEqual(Dollars.amount(0), "$0.00")
        XCTAssertEqual(Dollars.amount(-0.03), "-$0.03")
    }

    func testAnIconNamesALogoOrAnSFSymbol() {
        XCTAssertEqual(BrandIcon(name: "anthropic"), .logo("anthropic"))
        XCTAssertEqual(BrandIcon(name: "zai"), .logo("zai"))
        XCTAssertEqual(BrandIcon(name: "symbol:cloud.sun.fill"), .symbol("cloud.sun.fill"))
    }

    func testReduceMotionFollowsTheIPhoneUnlessSetHere() {
        XCTAssertTrue(ReduceMotionChoice.likeIPhone.reducesMotion(whenIPhoneDoes: true))
        XCTAssertFalse(ReduceMotionChoice.likeIPhone.reducesMotion(whenIPhoneDoes: false))
        XCTAssertTrue(ReduceMotionChoice.on.reducesMotion(whenIPhoneDoes: false))
        XCTAssertFalse(ReduceMotionChoice.off.reducesMotion(whenIPhoneDoes: true))
    }
}
