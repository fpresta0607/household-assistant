// What Connectors and a connector's page read from the gateway, in both shapes it answers:
// today's, with only `signIn` and a count of `accounts`, from which this build works out
// the rest, and PR 183's, with each connector's state, reason, capabilities, linked
// accounts and OAuth page. Then what each row and account says about it.

import XCTest
@testable import HouseholdAssistant

final class ConnectorAccountsTests: XCTestCase {
    private func settings(_ fixture: String) throws -> AssistantSettings {
        guard case .response(let response) = try GatewayCodec.decode(try Fixtures.text(fixture)) else {
            XCTFail("\(fixture) is not a response")
            throw GatewayConnectionError.unexpectedFrame
        }
        return try XCTUnwrap(response.payload).decoded(as: AssistantSettings.self)
    }

    private func connectors(_ fixture: String) throws -> [String: Connector] {
        Dictionary(uniqueKeysWithValues: try settings(fixture).connectors.map { ($0.id, $0) })
    }

    // MARK: - Today's gateway

    func testTodaysAnswerDecodesAndEverythingNewIsWorkedOutFromSignInAndAccounts() throws {
        let byId = try connectors("household-app-settings-response")
        let weather = try XCTUnwrap(byId["weather"])
        let icloud = try XCTUnwrap(byId["icloud"])
        let google = try XCTUnwrap(byId["gog"])

        XCTAssertEqual(try settings("household-app-settings-response").connectors.count, 12)
        XCTAssertEqual(weather.state, .connected, "it needs no sign-in")
        XCTAssertNil(weather.signInKind)
        XCTAssertEqual(icloud.signInKind, .password, "read from signIn")
        XCTAssertEqual(icloud.state, .connected, "its gateway holds one sign-in")
        XCTAssertEqual(google.signInKind, .oauth)
        XCTAssertEqual(google.state, .available, "its gateway holds none")
        for connector in byId.values {
            XCTAssertNil(connector.reason, connector.id)
            XCTAssertEqual(connector.capabilities, [], connector.id)
            XCTAssertEqual(connector.linkedAccounts, [], connector.id)
            XCTAssertNil(connector.oauth, connector.id)
        }
    }

    // MARK: - The accounts shape

    func testTheAccountsAnswerDecodesEachStateReasonCapabilityAccountAndPage() throws {
        let byId = try connectors("household-app-settings-accounts-response")
        let google = try XCTUnwrap(byId["gog"])
        let icloud = try XCTUnwrap(byId["icloud"])
        let notion = try XCTUnwrap(byId["notion"])
        let email = try XCTUnwrap(byId["himalaya"])

        XCTAssertEqual(google.state, .connected)
        XCTAssertEqual(google.capabilities, ["Reads your Gmail", "Reads and adds events in Google Calendar"])
        XCTAssertEqual(google.linkedAccounts.map(\.id), ["gog:app", "gog:box:1a2b3c4d"])
        let app = try XCTUnwrap(google.linkedAccounts.first)
        XCTAssertEqual(app.name, "Franco Marlowe")
        XCTAssertEqual(app.email, "franco@example.com")
        XCTAssertEqual(app.linkedDate, Date(timeIntervalSince1970: 1_792_018_799.5))
        XCTAssertEqual(app.status, .ok)
        XCTAssertTrue(app.canDisconnect)
        XCTAssertEqual(google.linkedAccounts.last?.status, .expired)
        XCTAssertEqual(google.oauth, ConnectorOAuth(
            provider: "google",
            clientId: "123456789012-abc123def456.apps.googleusercontent.com",
            authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
            scopes: OAuthAuthorization.googleScopes,
            redirectUri: "com.googleusercontent.apps.123456789012-abc123def456:/oauthredirect",
            usesPkce: true
        ))

        let onTheBox = try XCTUnwrap(icloud.linkedAccounts.first)
        XCTAssertEqual(onTheBox.id, "icloud:box")
        XCTAssertNil(onTheBox.email)
        XCTAssertNil(onTheBox.linkedDate)
        XCTAssertFalse(onTheBox.canDisconnect, "set in the gateway's env file")

        XCTAssertEqual(notion.signInKind, .token, "read from signInKind, not the null signIn kept for build 13")
        XCTAssertEqual(notion.state, .available)
        XCTAssertNil(notion.oauth)

        XCTAssertEqual(email.state, .unavailable)
        XCTAssertEqual(email.reason, "Not on this assistant")
        XCTAssertNil(email.signInKind)
    }

    func testSignInKindIsReadOverSignInAndANullOneMeansNoSignIn() throws {
        let connector = { (fields: String) in
            try JSONDecoder().decode(Connector.self, from: Data(#"""
                {"id":"c","name":"C","category":"notes","icon":"notion","summary":"s","isOn":true,"accounts":0,\#(fields)}
                """#.utf8))
        }
        let cases: [(fields: String, kind: ConnectorSignIn?)] = [
            (#""signIn":"oauth""#, .oauth),
            (#""signIn":null,"signInKind":"token""#, .token),
            (#""signIn":"oauth","signInKind":null"#, nil),
            (#""signIn":"password","signInKind":"password""#, .password),
        ]

        for (fields, kind) in cases {
            XCTAssertEqual(try connector(fields).signInKind, kind, fields)
        }
    }

    // MARK: - What a row and an account say

    func testTheLineUnderEachConnectorSaysWhyWhatItNeedsWhoItIsSignedInAsOrWhatItDoes() throws {
        let byId = try connectors("household-app-settings-accounts-response")
        let cases: [(id: String, line: String)] = [
            ("himalaya", "Not on this assistant"),
            ("notion", "Needs a token from Notion"),
            ("gog", "2 accounts"),
            ("icloud", "Set up on the assistant's computer"),
            ("weather", "Forecasts and conditions"),
        ]

        for (id, line) in cases {
            XCTAssertEqual(byId[id]?.line, line, id)
        }
    }

    func testNoConnectedConnectorSaysTheWordConnectedSinceItsGreenDotDoes() throws {
        for fixture in ["household-app-settings-response", "household-app-settings-accounts-response"] {
            let connected = try settings(fixture).connectors.filter(\.isConnected)

            XCTAssertFalse(connected.isEmpty, fixture)
            for connector in connected {
                XCTAssertFalse(connector.line.contains("Connected"), "\(fixture) \(connector.id): \(connector.line)")
            }
        }
    }

    func testTheConnectedGroupHasNoHeadingWhileTheOthersAreNamed() {
        XCTAssertEqual(ConnectorState.allCases.map(\.title), [nil, "Not connected", "Unavailable"])
    }

    func testAPasswordSignInAsksForAnAppPasswordOnlyWhereTheProviderTakesNothingElse() throws {
        let waiting = { (id: String, name: String) in
            try JSONDecoder().decode(Connector.self, from: Data(#"""
                {"id":"\#(id)","name":"\#(name)","category":"faith","icon":"siqsermon","summary":"s","isOn":true,"signIn":"password","accounts":0}
                """#.utf8))
        }

        XCTAssertEqual(try waiting("icloud", "iCloud").line, "Needs an app password")
        XCTAssertEqual(try waiting("himalaya", "Email").line, "Needs an app password")
        XCTAssertEqual(try waiting("scripture", "SIQsermon").line, "Needs your SIQsermon password")
    }

    func testOneAccountIsShownByItsAddress() throws {
        let google = try JSONDecoder().decode(Connector.self, from: Data(#"""
            {"id":"gog","name":"Google","category":"calendar-and-mail","icon":"google","summary":"Gmail and Google Calendar","isOn":true,
            "signIn":"oauth","accounts":1,"state":"connected","reason":null,"capabilities":[],"signInKind":"oauth",
            "linkedAccounts":[{"id":"gog:app","name":"Gia Marlowe","email":"gia@example.com","linkedAt":1792018799500,"status":"ok","abilities":[],"canDisconnect":true}],
            "oauth":null}
            """#.utf8))

        XCTAssertEqual(google.line, "gia@example.com")
        XCTAssertNil(google.signInNeed)
    }

    func testAnAccountSaysWhenItsSignInNoLongerWorksAndHowToSignInAgain() {
        let account = { (status: LinkedAccount.Status) in
            LinkedAccount(id: "gog:app", name: "Gia", email: nil, linkedAt: nil, status: status, abilities: [], canDisconnect: true)
        }
        let cases: [(status: LinkedAccount.Status, words: String?, switchWords: String)] = [
            (.ok, nil, "Switch account"),
            (.expired, "Its sign-in has expired", "Sign in again"),
            (.failing, "Not working right now", "Switch account"),
        ]

        for (status, words, switchWords) in cases {
            XCTAssertEqual(account(status).statusWords, words, status.rawValue)
            XCTAssertEqual(account(status).switchWords, switchWords, status.rawValue)
        }
    }
}
