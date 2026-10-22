// Connector sign-ins from the phone's side: what the gateway reads back for each
// connector, the PKCE pair, Google's sign-in page and a page the gateway describes, what
// the phone signs to connect, switch account or disconnect, exactly as
// deploy/openclaw/plugins/household-app/connect.js checks it, and what the row shows while
// it goes, once it lands and when it is refused. Driven over a scripted gateway, as Gia's
// phone with Denise.

import XCTest
@testable import HouseholdAssistant

final class ConnectorSignInTests: XCTestCase {
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

    /// A refusal as the gateway sends one, naming its rule in `details.detailCode` when given.
    private static func refused(_ request: GatewayRequest, _ message: String, detailCode: String? = nil) -> String {
        let details = detailCode.map { #","details":{"detailCode":"\#($0)"}"# } ?? ""
        return #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"\#(message)"\#(details)}}"#
    }

    /// Notion's redirect as the gateway describes it: a page that hands the answer on to
    /// steward://connector/notion.
    private static let notionRedirect = "https://www.siqstack.com/steward-ai/notion-callback"
    private static let notionPaste = "fixture-notion-paste-0001"

    /// Denise's settings as PR 183's connect.js shapes them: Gia's own Google account and an
    /// older one gog holds on the box, whose sign-in has expired, Notion signing in by
    /// `notion`'s kind, linked or not, Outlook, which only Corey has, and the weather.
    private static func linkedSettings(notion: String = "token", isNotionLinked: Bool = false) -> String {
        let notionOAuth = notion == "oauth"
            ? #"{"provider":"notion","clientId":"notion-client-1","authorizeUrl":"https://api.notion.com/v1/oauth/authorize?owner=user","scopes":[],"redirectUri":"\#(notionRedirect)","usesPkce":false}"#
            : "null"
        let notionAccounts = isNotionLinked
            ? #"[{"id":"notion:app","name":"Gia's Notion","email":null,"linkedAt":1792018799500,"status":"ok","abilities":["Reads and edits the pages you share with it in Gia's Notion"],"canDisconnect":true}]"#
            : "[]"
        let notionAccountCount = isNotionLinked ? 1 : 0
        let notionState = isNotionLinked ? "connected" : "available"
        return #"""
        {"assistant":{"name":"Denise","voice":"jessica","tone":40,"length":"balanced"},
        "voices":[{"id":"jessica","name":"Jessica","summary":"Young woman, bright and kind"}],
        "model":{"id":"z-ai/glm-5.3-flash","name":"GLM 5.3 Flash","company":"Z.ai","icon":"zai","fallbacks":[]},
        "connectors":[
        {"id":"gog","name":"Google","category":"calendar-and-mail","icon":"google","summary":"Gmail and Google Calendar","isOn":true,"signIn":"oauth","accounts":2,
        "state":"connected","reason":null,"capabilities":["Reads your Gmail","Reads and adds events in Google Calendar"],"signInKind":"oauth",
        "linkedAccounts":[
        {"id":"gog:app","name":"Gia Marlowe","email":"gia@example.com","linkedAt":1792018799500,"status":"ok","abilities":["Reads your Gmail","Reads and adds events in Google Calendar"],"canDisconnect":true},
        {"id":"gog:box:1a2b3c4d","name":"gia.old@example.com","email":"gia.old@example.com","linkedAt":1789426800000,"status":"expired","abilities":["Reads your Gmail"],"canDisconnect":true}],
        "oauth":{"provider":"google","clientId":"\#(clientId)","authorizeUrl":"https://accounts.google.com/o/oauth2/v2/auth","scopes":["openid","email","profile","https://www.googleapis.com/auth/gmail.readonly","https://www.googleapis.com/auth/calendar"],"redirectUri":"\#(redirect)","usesPkce":true}},
        {"id":"notion","name":"Notion","category":"notes","icon":"notion","summary":"Pages and databases in Notion","isOn":true,"signIn":null,"accounts":\#(notionAccountCount),
        "state":"\#(notionState)","reason":null,"capabilities":["Reads the Notion pages you share with it","Adds and edits pages there when you ask"],"signInKind":"\#(notion)",
        "linkedAccounts":\#(notionAccounts),"oauth":\#(notionOAuth)},
        {"id":"outlook-hack","name":"Outlook","category":"calendar-and-mail","icon":"symbol:envelope","summary":"Outlook mail and calendar","isOn":true,"signIn":null,"accounts":0,
        "state":"unavailable","reason":"Not on this assistant","capabilities":["Reads your Outlook mail"],"signInKind":null,"linkedAccounts":[],"oauth":null},
        {"id":"weather","name":"Weather","category":"everyday","icon":"symbol:cloud.sun","summary":"Forecasts and conditions","isOn":true,"signIn":null,"accounts":0,
        "state":"connected","reason":null,"capabilities":["Gives forecasts and current conditions"],"signInKind":null,"linkedAccounts":[],"oauth":null}],
        "notifications":{}}
        """#
    }

    /// Denise's settings as connectors.js shapes them, with how many sign-ins her gateway
    /// holds for iCloud and for Google.
    private static func settings(icloud: Int = 0, google: Int = 0) -> String {
        #"""
        {"assistant":{"name":"Denise","voice":"jessica","tone":40,"length":"balanced"},
        "voices":[{"id":"jessica","name":"Jessica","summary":"Young woman, bright and kind"}],
        "model":{"id":"z-ai/glm-5.3-flash","name":"GLM 5.3 Flash","company":"Z.ai","icon":"zai","fallbacks":[]},
        "connectors":[
        {"id":"icloud","name":"iCloud","category":"calendar-and-mail","icon":"icloud","summary":"Calendars and reminders in iCloud","isOn":true,"signIn":"password","accounts":\#(icloud)},
        {"id":"gog","name":"Google","category":"calendar-and-mail","icon":"google","summary":"Gmail and Google Calendar","isOn":true,"signIn":"oauth","accounts":\#(google)},
        {"id":"weather","name":"Weather","category":"everyday","icon":"symbol:cloud.sun","summary":"Forecasts and conditions","isOn":true,"signIn":null,"accounts":0}],
        "notifications":{}}
        """#
    }

    /// The client id in google-connect's own tests, and the redirect it allows for it.
    private static let clientId = "123456789012-abc123def456.apps.googleusercontent.com"
    private static let redirect = "com.googleusercontent.apps.123456789012-abc123def456:/oauthredirect"

    /// RFC 7636, Appendix B: the 32 octets, the verifier they make, and its S256 challenge.
    private static let rfcOctets: [UInt8] = [
        116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
        22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121,
    ]
    private static let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private static let rfcDigest: [UInt8] = [
        19, 211, 30, 150, 26, 26, 216, 236, 47, 22, 177, 12, 76, 152, 46, 8,
        118, 168, 120, 173, 109, 241, 68, 86, 110, 225, 137, 74, 203, 112, 249, 195,
    ]
    private static let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    /// The RFC's pair, its SHA-256 given here since Linux has no CryptoKit.
    private static var rfcPKCE: PKCE {
        PKCE(secret: rfcOctets) { $0 == Array(rfcVerifier.utf8) ? rfcDigest : [] }
    }

    private static func authorization(state: String = "state-1") throws -> OAuthAuthorization {
        try XCTUnwrap(OAuthAuthorization(googleClientId: clientId, pkce: rfcPKCE, state: state))
    }

    /// The shared test vector's moment.
    private let clock = Date(timeIntervalSince1970: 1_760_000_000)

    /// A model that has read Denise's settings.
    @MainActor
    private func loaded(_ gateway: Gateway, icloud: Int = 0, google: Int = 0) async throws -> AssistantSettingsModel {
        gateway.answers["household-app.settings"] = { Self.ok($0, Self.settings(icloud: icloud, google: google)) }
        try await gateway.connect()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, now: { [unowned self] in self.clock })
        await model.load()
        XCTAssertNotNil(model.current)
        return model
    }

    /// A model that has read Denise's settings with her accounts listed.
    @MainActor
    private func loadedWithAccounts(_ gateway: Gateway, notion: String = "token", isNotionLinked: Bool = false) async throws -> AssistantSettingsModel {
        gateway.answers["household-app.settings"] = { Self.ok($0, Self.linkedSettings(notion: notion, isNotionLinked: isNotionLinked)) }
        try await gateway.connect()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, now: { [unowned self] in self.clock })
        await model.load()
        XCTAssertNotNil(model.current)
        return model
    }

    @MainActor
    private func connector(_ id: String, in model: AssistantSettingsModel) throws -> Connector {
        try XCTUnwrap(model.current?.connectors.first { $0.id == id })
    }

    @MainActor
    private func eventually(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var attemptsLeft = 400
        while attemptsLeft > 0, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
    }

    // MARK: - What the gateway reads back

    func testEachConnectorReadsBackHowItSignsInAndHowManySignInsTheGatewayHolds() throws {
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings(icloud: 0, google: 2).utf8))
        let byId = Dictionary(uniqueKeysWithValues: settings.connectors.map { ($0.id, $0) })

        XCTAssertEqual(byId["icloud"]?.signInKind, .password)
        XCTAssertEqual(byId["gog"]?.signInKind, .oauth)
        XCTAssertNil(byId["weather"]?.signInKind)
        XCTAssertEqual(settings.connectors.map(\.accounts), [0, 2, 0])
        XCTAssertEqual(settings.connectors.map(\.isConnected), [false, true, true], "one that needs no sign-in is connected")
    }

    func testTheRowCountsTheAccountsWithoutTheWordConnectedOrSaysWhatItNeeds() throws {
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings(icloud: 1, google: 2).utf8))
        let none = try JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings().utf8))

        XCTAssertEqual(settings.connectors.map(\.connectedWords), ["1 account", "2 accounts", nil])
        XCTAssertEqual(none.connectors.map(\.connectedWords), [nil, nil, nil])
        XCTAssertEqual(none.connectors.map(\.signInNeed), ["Needs an app password", "Needs your Google sign-in", nil])
    }

    // MARK: - PKCE and Google's page

    func testThePKCEPairIsRFC7636sAppendixB() {
        let pkce = Self.rfcPKCE

        XCTAssertEqual(pkce.verifier.revealed, Self.rfcVerifier)
        XCTAssertEqual(pkce.challenge, Self.rfcChallenge, "S256 hashes the verifier's own characters, not the octets")
    }

    #if canImport(CryptoKit)
    func testCryptoKitsSHA256GivesTheRFCChallengeAndAFreshVerifierIsSixtyFourRandomBytes() throws {
        XCTAssertEqual(PKCE(secret: Self.rfcOctets).challenge, Self.rfcChallenge)

        let first = PKCE.fresh()
        let second = PKCE.fresh()

        XCTAssertEqual(Base64URL.decode(first.verifier.revealed)?.count, 64)
        XCTAssertEqual(first.verifier.revealed.count, 86, "within RFC 7636's 43 to 128")
        XCTAssertNotEqual(first.verifier, second.verifier, "fresh each time")
        XCTAssertEqual(PKCE(secret: Array(try XCTUnwrap(Base64URL.decode(first.verifier.revealed)))).challenge, first.challenge)
    }
    #endif

    func testGooglesPageAsksForMailCalendarAndTheNameWithAnS256ChallengeOnTheReversedClientId() throws {
        let authorization = try Self.authorization()
        let page = try XCTUnwrap(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (page.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(page.scheme, "https")
        XCTAssertEqual(page.host, "accounts.google.com")
        XCTAssertEqual(page.path, "/o/oauth2/v2/auth")
        XCTAssertEqual(items, [
            "client_id": Self.clientId,
            "redirect_uri": Self.redirect,
            "response_type": "code",
            "scope": "openid email profile https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar",
            "code_challenge": Self.rfcChallenge,
            "code_challenge_method": "S256",
            "state": "state-1",
        ])
        XCTAssertFalse(authorization.url.absoluteString.contains(Self.rfcVerifier), "the verifier never leaves for Google's page")
        XCTAssertEqual(authorization.redirectURI, Self.redirect, "the redirect google-connect.js allows this client")
        XCTAssertEqual(authorization.callbackScheme, "com.googleusercontent.apps.123456789012-abc123def456")
    }

    func testOnlyAGoogleIOSClientIdIsTakenSoThePlaceholderIsRefused() {
        let cases: [(String, Bool)] = [
            (Self.clientId, true),
            ("placeholder-ios-client-id.apps.googleusercontent.com", false),
            ("123456789012-abc123def456.apps.googleusercontent.com.apps.googleusercontent.com", false),
            ("123456789012-abc123def456", false),
            ("123456789012-ABC.apps.googleusercontent.com", false),
            ("-abc.apps.googleusercontent.com", false),
            ("", false),
        ]
        for (clientId, isTaken) in cases {
            XCTAssertEqual(OAuthAuthorization(googleClientId: clientId, pkce: Self.rfcPKCE) != nil, isTaken, clientId)
        }
    }

    func testGooglesAnswerGivesTheCodeOnlyForThisSignIn() throws {
        let authorization = try Self.authorization()
        let answer = { (query: String) in URL(string: "\(Self.redirect)?\(query)")! }

        XCTAssertEqual(try authorization.code(from: answer("state=state-1&code=4/0Acode&scope=email")).revealed, "4/0Acode")
        XCTAssertThrowsError(try authorization.code(from: answer("state=state-2&code=4/0Acode"))) { error in
            XCTAssertEqual(error as? OAuthSignInFailure, .notThisSignIn(provider: "Google"))
        }
        XCTAssertThrowsError(try authorization.code(from: answer("state=state-1&error=access_denied"))) { error in
            XCTAssertEqual(error as? OAuthSignInFailure, .declined(provider: "Google", code: "access_denied"))
            XCTAssertEqual(ErrorText.describe(error), "Google sign-in was turned down, so nothing changed.")
        }
        XCTAssertThrowsError(try authorization.code(from: answer("state=state-1"))) { error in
            XCTAssertEqual(error as? OAuthSignInFailure, .notThisSignIn(provider: "Google"))
        }
    }

    // MARK: - What the phone signs

    func testTheSharedVectorForConnectAndDisconnectMatchesConnectJS() {
        let google = ConnectorChange(
            at: 1_760_000_000_000,
            connector: "gog",
            action: .connect(.oauth(code: SecretText("c"), codeVerifier: SecretText("v"), redirectUri: "r"), replacing: nil)
        )
        let password = ConnectorChange(
            at: 1_760_000_000_000,
            connector: "himalaya",
            action: .connect(.password(username: "gia@example.com", secret: SecretText("abcd-efgh-ijkl-mnop")), replacing: nil)
        )
        let disconnect = ConnectorChange(at: 1_760_000_000_000, connector: "gog", action: .disconnect(account: nil))

        XCTAssertEqual(google.signedText, "household-app/connect/v1\n1760000000000\nconnect\ngog\nc\nv\nr")
        XCTAssertEqual(password.signedText, "household-app/connect/v1\n1760000000000\nconnect\nhimalaya\ngia@example.com\nabcd-efgh-ijkl-mnop")
        XCTAssertEqual(disconnect.signedText, "household-app/connect/v1\n1760000000000\ndisconnect\ngog")
        XCTAssertEqual(google.method, "household-app.connector.connect")
        XCTAssertEqual(disconnect.method, "household-app.connector.disconnect")
        XCTAssertEqual(google.params(signature: "sig"), .object([
            "at": .number(1_760_000_000_000),
            "connector": .string("gog"),
            "code": .string("c"),
            "codeVerifier": .string("v"),
            "redirectUri": .string("r"),
            "signature": .string("sig"),
        ]))
        XCTAssertEqual(password.params(signature: "sig"), .object([
            "at": .number(1_760_000_000_000),
            "connector": .string("himalaya"),
            "username": .string("gia@example.com"),
            "secret": .string("abcd-efgh-ijkl-mnop"),
            "signature": .string("sig"),
        ]))
        XCTAssertEqual(disconnect.params(signature: "sig"), .object([
            "at": .number(1_760_000_000_000),
            "connector": .string("gog"),
            "signature": .string("sig"),
        ]))
    }

    func testNotionsCodeATokenSwitchAccountAndOneAccountsDisconnectSignAsConnectJSChecksThem() {
        let at = 1_760_000_000_000
        let cases: [(change: ConnectorChange, signed: String, params: [String: JSONValue])] = [
            (
                ConnectorChange(at: at, connector: "notion", action: .connect(.oauth(code: SecretText("c"), codeVerifier: nil, redirectUri: "r"), replacing: nil)),
                "household-app/connect/v1\n1760000000000\nconnect\nnotion\nc\nr",
                ["code": .string("c"), "redirectUri": .string("r")]
            ),
            (
                ConnectorChange(at: at, connector: "notion", action: .connect(.token(SecretText("t")), replacing: nil)),
                "household-app/connect/v1\n1760000000000\nconnect\nnotion\nt",
                ["token": .string("t")]
            ),
            (
                ConnectorChange(
                    at: at,
                    connector: "gog",
                    action: .connect(.oauth(code: SecretText("c"), codeVerifier: SecretText("v"), redirectUri: "r"), replacing: "gog:box:1a2b3c4d")
                ),
                "household-app/connect/v1\n1760000000000\nconnect\ngog\nc\nv\nr\ngog:box:1a2b3c4d",
                ["code": .string("c"), "codeVerifier": .string("v"), "redirectUri": .string("r"), "replacing": .string("gog:box:1a2b3c4d")]
            ),
            (
                ConnectorChange(at: at, connector: "icloud", action: .connect(.password(username: "u", secret: SecretText("s")), replacing: "icloud:app")),
                "household-app/connect/v1\n1760000000000\nconnect\nicloud\nu\ns\nicloud:app",
                ["username": .string("u"), "secret": .string("s"), "replacing": .string("icloud:app")]
            ),
            (
                ConnectorChange(at: at, connector: "notion", action: .connect(.token(SecretText("t")), replacing: "notion:app")),
                "household-app/connect/v1\n1760000000000\nconnect\nnotion\nt\nnotion:app",
                ["token": .string("t"), "replacing": .string("notion:app")]
            ),
            (
                ConnectorChange(at: at, connector: "gog", action: .disconnect(account: "gog:box:1a2b3c4d")),
                "household-app/connect/v1\n1760000000000\ndisconnect\ngog\ngog:box:1a2b3c4d",
                ["accountId": .string("gog:box:1a2b3c4d")]
            ),
        ]

        for (change, signed, values) in cases {
            XCTAssertEqual(change.signedText, signed)
            var params: [String: JSONValue] = ["at": .number(1_760_000_000_000), "connector": .string(change.connector), "signature": .string("sig")]
            params.merge(values) { _, value in value }
            XCTAssertEqual(change.params(signature: "sig"), .object(params), signed)
        }
    }

    // MARK: - A page the gateway describes

    func testNotionsPageKeepsItsOwnQueryTakesNoPKCEAndAnswersOnTheAppsScheme() throws {
        let oauth = ConnectorOAuth(
            provider: "notion",
            clientId: "notion-client-1",
            authorizeUrl: "https://api.notion.com/v1/oauth/authorize?owner=user",
            scopes: [],
            redirectUri: Self.notionRedirect,
            usesPkce: false
        )
        let authorization = try XCTUnwrap(OAuthAuthorization(described: oauth, provider: "Notion", pkce: Self.rfcPKCE, state: "state-n"))
        let page = try XCTUnwrap(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(page.scheme, "https")
        XCTAssertEqual(page.host, "api.notion.com")
        XCTAssertEqual(page.path, "/v1/oauth/authorize")
        XCTAssertEqual(page.queryItems, [
            URLQueryItem(name: "owner", value: "user"),
            URLQueryItem(name: "client_id", value: "notion-client-1"),
            URLQueryItem(name: "redirect_uri", value: Self.notionRedirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: "state-n"),
        ], "no scope when it asks for none, and no challenge without PKCE")
        XCTAssertNil(authorization.pkce)
        XCTAssertEqual(authorization.callbackScheme, "steward", "whatever the redirect's scheme")
        XCTAssertEqual(
            authorization.credential(code: SecretText("n-code")),
            .oauth(code: SecretText("n-code"), codeVerifier: nil, redirectUri: Self.notionRedirect),
            "the redirect goes back exactly as the gateway gave it"
        )
        XCTAssertEqual(try authorization.code(from: URL(string: "steward://connector/notion?code=n-code&state=state-n")!).revealed, "n-code")
        XCTAssertThrowsError(try authorization.code(from: URL(string: "steward://connector/notion?code=n-code&state=state-1")!)) { error in
            XCTAssertEqual(ErrorText.describe(error), "Notion answered a different sign-in, so it was not used.")
        }
    }

    func testADescribedProviderThatTakesPKCEGetsTheChallengeItsScopesAndOurOwnValuesOnly() throws {
        let oauth = ConnectorOAuth(
            provider: "example",
            clientId: "example-client",
            authorizeUrl: "https://example.com/authorize?client_id=stale&prompt=consent",
            scopes: ["read", "write"],
            redirectUri: "com.example.app:/callback",
            usesPkce: true
        )
        let authorization = try XCTUnwrap(OAuthAuthorization(described: oauth, provider: "Example", pkce: Self.rfcPKCE, state: "state-e"))
        let items = try XCTUnwrap(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(items, [
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "client_id", value: "example-client"),
            URLQueryItem(name: "redirect_uri", value: "com.example.app:/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "read write"),
            URLQueryItem(name: "code_challenge", value: Self.rfcChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: "state-e"),
        ], "the page's own client_id gives way to the gateway's, and is never sent twice")
        XCTAssertFalse(authorization.url.absoluteString.contains(Self.rfcVerifier))
        XCTAssertEqual(authorization.callbackScheme, "steward")
        XCTAssertEqual(
            authorization.credential(code: SecretText("e-code")),
            .oauth(code: SecretText("e-code"), codeVerifier: SecretText(Self.rfcVerifier), redirectUri: "com.example.app:/callback")
        )
        let insecure = ConnectorOAuth(provider: "example", clientId: "c", authorizeUrl: "http://example.com/authorize", scopes: [], redirectUri: "r", usesPkce: false)
        XCTAssertNil(OAuthAuthorization(described: insecure, provider: "Example", pkce: Self.rfcPKCE), "only an https page is opened")
    }

    func testGoogleKeepsItsOwnFlowWithPKCEWhetherOrNotItsGatewayDescribesIt() throws {
        let described = try XCTUnwrap(JSONDecoder().decode(AssistantSettings.self, from: Data(Self.linkedSettings().utf8)).connectors.first { $0.id == "gog" })
        let older = try XCTUnwrap(JSONDecoder().decode(AssistantSettings.self, from: Data(Self.settings().utf8)).connectors.first { $0.id == "gog" })
        XCTAssertNotNil(described.oauth)
        XCTAssertNil(older.oauth)

        for google in [described, older] {
            let authorization = try XCTUnwrap(OAuthAuthorization(for: google, googleClientId: Self.clientId, pkce: Self.rfcPKCE, state: "state-1"))
            XCTAssertEqual(authorization.url, try Self.authorization().url)
            XCTAssertEqual(authorization.callbackScheme, "com.googleusercontent.apps.123456789012-abc123def456", "Google answers on its own scheme")
            XCTAssertEqual(authorization.pkce?.challenge, Self.rfcChallenge)
        }
        XCTAssertNil(OAuthAuthorization(for: described, googleClientId: "placeholder-ios-client-id.apps.googleusercontent.com", pkce: Self.rfcPKCE))

        let notion = try XCTUnwrap(JSONDecoder().decode(AssistantSettings.self, from: Data(Self.linkedSettings(notion: "oauth").utf8)).connectors.first { $0.id == "notion" })
        let authorization = try XCTUnwrap(OAuthAuthorization(for: notion, googleClientId: Self.clientId, pkce: Self.rfcPKCE))
        XCTAssertEqual(authorization.page.host, "api.notion.com")
        XCTAssertEqual(authorization.provider, "Notion")
        XCTAssertNil(authorization.pkce)
    }

    @MainActor
    func testNotionsCodeGoesSignedWithItsRedirectAndNoVerifierAndThePageListsTheAccount() async throws {
        let gateway = Gateway()
        let model = try await loadedWithAccounts(gateway, notion: "oauth")
        gateway.answers["household-app.connector.connect"] = { Self.ok($0, Self.linkedSettings(notion: "oauth", isNotionLinked: true)) }
        let notion = try connector("notion", in: model)
        var shown: [String] = []

        await model.connectOAuth(notion, with: OAuthAuthorization(for: notion, googleClientId: Self.clientId, pkce: Self.rfcPKCE, state: "state-n")) { _, scheme in
            shown.append(scheme)
            return URL(string: "steward://connector/notion?code=n-code&state=state-n")!
        }

        XCTAssertEqual(shown, ["steward"])
        XCTAssertEqual(gateway.signed, ["household-app/connect/v1\n1760000000000\nconnect\nnotion\nn-code\n\(Self.notionRedirect)"])
        XCTAssertEqual(gateway.requests("household-app.connector.connect").first?.params, .object([
            "at": .number(1_760_000_000_000),
            "connector": .string("notion"),
            "code": .string("n-code"),
            "redirectUri": .string(Self.notionRedirect),
            "signature": .string("phone-signature-1"),
        ]))
        XCTAssertEqual(try connector("notion", in: model).state, .connected)
        XCTAssertEqual(try connector("notion", in: model).linkedAccounts.map(\.id), ["notion:app"])
        XCTAssertNil(model.refusal)
    }

    @MainActor
    func testAProviderTheAppHasNeverHeardOfSignsInWithPKCEFromItsDescriptionAlone() async throws {
        let outlook = #"""
            {"id":"outlook-hack","name":"Outlook","category":"calendar-and-mail","icon":"symbol:envelope","summary":"Outlook mail and calendar","isOn":true,
            "signIn":null,"accounts":0,"state":"available","reason":null,"capabilities":["Reads your Outlook mail"],"signInKind":"oauth","linkedAccounts":[],
            "oauth":{"provider":"outlook","clientId":"outlook-client-1","authorizeUrl":"https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "scopes":["offline_access","Mail.Read"],"redirectUri":"steward://connector/outlook","usesPkce":true}}
            """#
        let settings = #"""
            {"assistant":{"name":"Corey","voice":"will","tone":64,"length":"balanced"},"voices":[],
            "model":{"id":"z-ai/glm-5.3-flash","name":"GLM 5.3 Flash","company":"Z.ai","icon":"zai","fallbacks":[]},
            "connectors":[\#(outlook)],"notifications":{}}
            """#
        let gateway = Gateway()
        gateway.answers["household-app.settings"] = { Self.ok($0, settings) }
        try await gateway.connect()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, now: { [unowned self] in self.clock })
        await model.load()
        gateway.answers["household-app.connector.connect"] = { Self.ok($0, settings) }
        let connector = try connector("outlook-hack", in: model)
        var shown: [(page: URL, scheme: String)] = []

        await model.connectOAuth(connector, with: OAuthAuthorization(for: connector, googleClientId: Self.clientId, pkce: Self.rfcPKCE, state: "state-o")) { page, scheme in
            shown.append((page, scheme))
            return URL(string: "steward://connector/outlook?code=o-code&state=state-o")!
        }

        let page = try XCTUnwrap(shown.first)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: page.page, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(page.page.host, "login.microsoftonline.com")
        XCTAssertEqual(page.scheme, "steward")
        XCTAssertEqual(items["code_challenge"], Self.rfcChallenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], "offline_access Mail.Read")
        XCTAssertEqual(items["redirect_uri"], "steward://connector/outlook")
        XCTAssertEqual(gateway.signed, ["household-app/connect/v1\n1760000000000\nconnect\noutlook-hack\no-code\n\(Self.rfcVerifier)\nsteward://connector/outlook"])
        XCTAssertEqual(gateway.requests("household-app.connector.connect").first?.params, .object([
            "at": .number(1_760_000_000_000),
            "connector": .string("outlook-hack"),
            "code": .string("o-code"),
            "codeVerifier": .string(Self.rfcVerifier),
            "redirectUri": .string("steward://connector/outlook"),
            "signature": .string("phone-signature-1"),
        ]))
        XCTAssertNil(model.refusal)
    }

    // MARK: - Switching and disconnecting one account

    @MainActor
    func testSwitchAccountSignsTheReplacedAccountLastAndDisconnectNamesOneAccount() async throws {
        let gateway = Gateway()
        let model = try await loadedWithAccounts(gateway, isNotionLinked: true)
        gateway.answers["household-app.connector.connect"] = { Self.ok($0, Self.linkedSettings(isNotionLinked: true)) }
        gateway.answers["household-app.connector.disconnect"] = { Self.ok($0, Self.linkedSettings(isNotionLinked: true)) }
        let notion = try connector("notion", in: model)
        let google = try connector("gog", in: model)
        let box = try XCTUnwrap(google.linkedAccounts.last)

        await model.connect(notion, with: .token(SecretText(Self.notionPaste)), replacing: try XCTUnwrap(notion.linkedAccounts.first))
        await model.connectOAuth(google, replacing: box, with: try Self.authorization()) { _, _ in
            URL(string: "\(Self.redirect)?state=state-1&code=4/0Acode")!
        }
        await model.disconnect(google, account: box)

        XCTAssertEqual(gateway.signed, [
            "household-app/connect/v1\n1760000000000\nconnect\nnotion\n\(Self.notionPaste)\nnotion:app",
            "household-app/connect/v1\n1760000000001\nconnect\ngog\n4/0Acode\n\(Self.rfcVerifier)\n\(Self.redirect)\ngog:box:1a2b3c4d",
            "household-app/connect/v1\n1760000000002\ndisconnect\ngog\ngog:box:1a2b3c4d",
        ])
        XCTAssertEqual(gateway.requests("household-app.connector.connect").first?.params, .object([
            "at": .number(1_760_000_000_000),
            "connector": .string("notion"),
            "token": .string(Self.notionPaste),
            "replacing": .string("notion:app"),
            "signature": .string("phone-signature-1"),
        ]))
        XCTAssertEqual(gateway.requests("household-app.connector.connect").last?.params["replacing"], .string("gog:box:1a2b3c4d"))
        XCTAssertEqual(gateway.requests("household-app.connector.disconnect").first?.params, .object([
            "at": .number(1_760_000_000_002),
            "connector": .string("gog"),
            "accountId": .string("gog:box:1a2b3c4d"),
            "signature": .string("phone-signature-3"),
        ]))
        XCTAssertNil(model.refusal)
    }

    // MARK: - The list

    /// The gateway's catalog lists iCloud and Google before Notion, and Notion leads the
    /// ones not linked yet (CFO notes section 4), the rest in the gateway's order.
    @MainActor
    func testNotionLeadsTheConnectorsNotLinkedYet() async throws {
        // Arrange
        let gateway = Gateway()
        let unlinked = { (id: String, name: String) in
            #"{"id":"\#(id)","name":"\#(name)","category":"notes","icon":"\#(id)","summary":"","isOn":true,"signIn":null,"accounts":0,"state":"available","reason":null,"capabilities":[],"signInKind":"token","linkedAccounts":[],"oauth":null}"#
        }
        let connectors = [unlinked("icloud", "iCloud"), unlinked("gog", "Google"), unlinked("notion", "Notion")].joined(separator: ",")
        gateway.answers["household-app.settings"] = {
            Self.ok($0, #"{"assistant":{"name":"Denise","voice":"jessica","tone":40,"length":"balanced"},"voices":[],"model":{"id":"z-ai/glm-5.3-flash","name":"GLM 5.3 Flash","company":"Z.ai","icon":"zai","fallbacks":[]},"connectors":[\#(connectors)],"notifications":{}}"#)
        }
        try await gateway.connect()
        let model = AssistantSettingsModel(connection: gateway.connection, sign: { gateway.sign($0) }, now: { [unowned self] in self.clock })

        // Act
        await model.load()

        // Assert
        XCTAssertEqual(model.connectors(.available).map(\.id), ["notion", "icloud", "gog"])
    }

    @MainActor
    func testConnectorsListsTheConnectedFirstThenTheWaitingThenTheUnavailableAndOnlyConnectedOnesAreOn() async throws {
        let gateway = Gateway()
        let model = try await loadedWithAccounts(gateway)
        let notion = try connector("notion", in: model)
        let outlook = try connector("outlook-hack", in: model)

        XCTAssertEqual(ConnectorState.allCases, [.connected, .available, .unavailable])
        XCTAssertEqual(model.connectors(.connected).map(\.id), ["gog", "weather"])
        XCTAssertEqual(model.connectors(.available).map(\.id), ["notion"])
        XCTAssertEqual(model.connectors(.unavailable).map(\.id), ["outlook-hack"])
        XCTAssertTrue(notion.isOn, "its gateway's config has it on")
        XCTAssertFalse(model.isOn(notion), "but it shows off until it is signed in")
        XCTAssertFalse(model.isOn(outlook))
        XCTAssertEqual(model.connectorsOn, 2)
    }

    // MARK: - Refusals

    @MainActor
    func testEachRuleARefusalNamesIsOnePlainLineAndAnyOtherIsTheGatewaysOwnSentence() async throws {
        let gateway = Gateway()
        let model = try await loadedWithAccounts(gateway)
        let notion = try connector("notion", in: model)
        let cases: [(detailCode: String?, line: String)] = [
            ("SIGNIN_NOT_SET_UP", "Notion sign-in is not set up on Denise's gateway yet."),
            ("PROVIDER_REFUSED", "Notion would not finish the sign-in, so nothing changed. Try again."),
            ("SCOPES_MISSING", "Notion did not allow all that Denise needs. Sign in again and allow everything."),
            ("NO_SUCH_ACCOUNT", "That Notion account is no longer linked, so there was nothing to change."),
            ("ACCOUNT_IS_ON_THE_BOX", "That sign-in is set up on Denise's computer, so it changes only there."),
            ("SIGNATURE", "Only your own iPhones can change Denise's connectors."),
            ("STALE", "Nothing changed, since Denise's gateway already has a newer change. Try again."),
            ("BAD_VALUE", "What was sent for Notion could not be used. Check it and try again."),
            ("A_RULE_FROM_LATER", "notion refused it"),
            (nil, "notion refused it"),
        ]

        for (detailCode, line) in cases {
            gateway.answers["household-app.connector.connect"] = { Self.refused($0, "notion refused it", detailCode: detailCode) }
            await model.connect(notion, with: .token(SecretText(Self.notionPaste)))
            XCTAssertEqual(model.refusal(for: [.connector("notion")]), line, detailCode ?? "no rule named")
            XCTAssertFalse(model.isSigningIn(notion))
        }
    }

    // MARK: - Connecting Google

    @MainActor
    func testGooglesCodeGoesSignedToTheGatewayWithItsVerifierAndTheRowReadsConnected() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.connector.connect"] = { Self.ok($0, Self.settings(google: 1)) }
        var shown: [(URL, String)] = []

        await model.connectOAuth(try connector("gog", in: model), with: try Self.authorization()) { page, scheme in
            shown.append((page, scheme))
            return URL(string: "\(Self.redirect)?state=state-1&code=4/0Acode")!
        }

        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.0, try Self.authorization().url)
        XCTAssertEqual(shown.first?.1, "com.googleusercontent.apps.123456789012-abc123def456")
        XCTAssertEqual(gateway.signed, ["household-app/connect/v1\n1760000000000\nconnect\ngog\n4/0Acode\n\(Self.rfcVerifier)\n\(Self.redirect)"])
        XCTAssertEqual(gateway.requests("household-app.connector.connect").first?.params, .object([
            "at": .number(1_760_000_000_000),
            "connector": .string("gog"),
            "code": .string("4/0Acode"),
            "codeVerifier": .string(Self.rfcVerifier),
            "redirectUri": .string(Self.redirect),
            "signature": .string("phone-signature-1"),
        ]))
        XCTAssertEqual(try connector("gog", in: model).accounts, 1, "the row shows what the gateway read back")
        XCTAssertFalse(model.isSigningIn(try connector("gog", in: model)))
        XCTAssertNil(model.refusal)
    }

    @MainActor
    func testClosingGooglesSheetChangesNothingAndSaysNothing() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)

        await model.connectOAuth(try connector("gog", in: model), with: try Self.authorization()) { _, _ in
            throw CancellationError()
        }

        XCTAssertTrue(gateway.requests("household-app.connector.connect").isEmpty)
        XCTAssertTrue(gateway.signed.isEmpty)
        XCTAssertNil(model.refusal)
    }

    @MainActor
    func testWithoutTheRealClientIdConnectSaysGoogleIsNotSetUpAndOpensNothing() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        var isShown = false

        await model.connectOAuth(try connector("gog", in: model), with: nil) { page, _ in
            isShown = true
            return page
        }

        XCTAssertFalse(isShown)
        XCTAssertTrue(gateway.requests("household-app.connector.connect").isEmpty)
        XCTAssertEqual(model.refusal(for: [.connector("gog")]), "Google sign-in is not set up in this build yet.")
    }

    @MainActor
    func testAnAnswerForAnotherSignInIsNeverSent() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)

        await model.connectOAuth(try connector("gog", in: model), with: try Self.authorization()) { _, _ in
            URL(string: "\(Self.redirect)?state=someone-else&code=4/0Aplanted")!
        }

        XCTAssertTrue(gateway.requests("household-app.connector.connect").isEmpty)
        XCTAssertEqual(model.refusal(for: [.connector("gog")]), "Google answered a different sign-in, so it was not used.")
    }

    // MARK: - A typed sign-in, and disconnecting

    @MainActor
    func testAnAppPasswordGoesSignedAndDisconnectingIsLaterOnTheSameClockAsSettings() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.settings.change"] = { Self.ok($0, Self.settings()) }
        gateway.answers["household-app.connector.connect"] = { Self.ok($0, Self.settings(icloud: 1)) }
        gateway.answers["household-app.connector.disconnect"] = { Self.ok($0, Self.settings(icloud: 0)) }
        let icloud = try connector("icloud", in: model)

        await model.change(.tone, to: "40")
        await model.connect(icloud, with: .password(username: "gia@example.com", secret: SecretText("abcd-efgh-ijkl-mnop")))
        XCTAssertEqual(try connector("icloud", in: model).accounts, 1)
        await model.disconnect(try connector("icloud", in: model))

        XCTAssertEqual(gateway.signed, [
            "household-app/settings/v1\n1760000000000\ntone\n40",
            "household-app/connect/v1\n1760000000001\nconnect\nicloud\ngia@example.com\nabcd-efgh-ijkl-mnop",
            "household-app/connect/v1\n1760000000002\ndisconnect\nicloud",
        ], "the gateway's replay guard is shared, so each is later than the last")
        XCTAssertEqual(gateway.requests("household-app.connector.disconnect").first?.params, .object([
            "at": .number(1_760_000_000_002),
            "connector": .string("icloud"),
            "signature": .string("phone-signature-3"),
        ]))
        XCTAssertEqual(try connector("icloud", in: model).accounts, 0)
    }

    @MainActor
    func testWhileASignInIsOnItsWayTheRowShowsASpinner() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        var held: GatewayRequest?
        gateway.answers["household-app.connector.connect"] = { request in
            held = request
            return nil
        }
        let icloud = try connector("icloud", in: model)

        let connecting = Task {
            await model.connect(icloud, with: .password(username: "gia@example.com", secret: SecretText("abcd-efgh-ijkl-mnop")))
        }
        await eventually("sent") { held != nil }

        XCTAssertTrue(model.isSigningIn(icloud))
        XCTAssertFalse(model.isSigningIn(try connector("gog", in: model)))

        gateway.transport.push(Self.ok(try XCTUnwrap(held), Self.settings(icloud: 1)))
        await connecting.value

        XCTAssertFalse(model.isSigningIn(icloud))
        XCTAssertTrue(try connector("icloud", in: model).isConnected)
    }

    @MainActor
    func testARefusalSaysWhyInOnePlainLineAndTheNextTryClearsIt() async throws {
        let gateway = Gateway()
        let model = try await loaded(gateway)
        gateway.answers["household-app.connector.connect"] = { Self.refused($0, "Google refused the sign-in (400, invalid_grant)") }

        await model.connectOAuth(try connector("gog", in: model), with: try Self.authorization()) { _, _ in
            URL(string: "\(Self.redirect)?state=state-1&code=4/0Acode")!
        }

        XCTAssertEqual(model.refusal(for: [.connector("gog")]), "Google refused the sign-in (400, invalid_grant)")
        XCTAssertNil(model.refusal(for: [.connector("icloud")]))
        XCTAssertEqual(try connector("gog", in: model).accounts, 0)
        XCTAssertFalse(model.isSigningIn(try connector("gog", in: model)))

        gateway.answers["household-app.connector.connect"] = { Self.ok($0, Self.settings(google: 1)) }
        await model.connectOAuth(try connector("gog", in: model), with: try Self.authorization()) { _, _ in
            URL(string: "\(Self.redirect)?state=state-1&code=4/0Acode")!
        }
        XCTAssertNil(model.refusal)
    }

    // MARK: - Never shown

    func testNoCodeVerifierOrPasswordShowsInAnyDescriptionDumpOrMirror() throws {
        let secrets = ["4/0Acode", Self.rfcVerifier, "abcd-efgh-ijkl-mnop", Self.notionPaste]
        let google = ConnectorCredential.oauth(code: SecretText("4/0Acode"), codeVerifier: Self.rfcPKCE.verifier, redirectUri: Self.redirect)
        let notion = ConnectorCredential.oauth(code: SecretText("4/0Acode"), codeVerifier: nil, redirectUri: Self.notionRedirect)
        let password = ConnectorCredential.password(username: "gia@example.com", secret: SecretText("abcd-efgh-ijkl-mnop"))
        let token = ConnectorCredential.token(SecretText(Self.notionPaste))
        let values: [Any] = [
            SecretText("abcd-efgh-ijkl-mnop"),
            Self.rfcPKCE,
            try Self.authorization(),
            google,
            notion,
            password,
            token,
            ConnectorChange(at: 1, connector: "gog", action: .connect(google, replacing: "gog:box:1a2b3c4d")),
            ConnectorChange(at: 1, connector: "notion", action: .connect(notion, replacing: nil)),
            ConnectorChange(at: 1, connector: "icloud", action: .connect(password, replacing: nil)),
            ConnectorChange(at: 1, connector: "notion", action: .connect(token, replacing: "notion:app")),
        ]

        for value in values {
            var dumped = ""
            dump(value, to: &dumped)
            let mirrored = Mirror(reflecting: value).children.map { String(describing: $0.value) }.joined()
            for text in [String(describing: value), String(reflecting: value), dumped, mirrored] {
                for secret in secrets {
                    XCTAssertFalse(text.contains(secret), "\(type(of: value)) shows a secret: \(text)")
                }
            }
        }
        let failures: [OAuthSignInFailure] = [
            .notSetUp(provider: "Google"),
            .notThisSignIn(provider: "Notion"),
            .declined(provider: "Google", code: "access_denied"),
            .declined(provider: "Notion", code: "server_error"),
        ]
        for failure in failures {
            XCTAssertFalse(secrets.contains { ErrorText.describe(failure).contains($0) })
        }
    }
}
