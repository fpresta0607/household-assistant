// What Connectors and a connector's page say about a connector: the line under its name,
// the account it is signed in with or how many, what it needs before it can be used, and
// why its gateway would not take a sign-in or a sign-out, in one plain line.

import Foundation

extension Connector {
    /// Under its name in Connectors: why this gateway cannot have it, what it needs, the
    /// account it is signed in with, or what it does.
    var line: String {
        switch state {
        case .unavailable:
            return reason ?? summary
        case .available:
            return signInNeed ?? summary
        case .connected:
            return connectedWords ?? summary
        }
    }

    /// The one account it is signed in with by its address, or "2 accounts", once its
    /// gateway holds a sign-in. An older gateway counts them and lists none. Never the word
    /// Connected: the green dot before the line says that.
    var connectedWords: String? {
        guard signInKind != nil, accounts >= 1 || !linkedAccounts.isEmpty else {
            return nil
        }
        if linkedAccounts.count == 1, let only = linkedAccounts.first {
            return only.email ?? only.name
        }
        let count = linkedAccounts.isEmpty ? accounts : linkedAccounts.count
        return "\(count) \(count == 1 ? "account" : "accounts")"
    }

    /// What it needs while it waits for its person's sign-in.
    var signInNeed: String? {
        guard state == .available else {
            return nil
        }
        switch signInKind {
        case .oauth:
            return "Needs your \(name) sign-in"
        case .password:
            return usesAppPassword ? "Needs an app password" : "Needs your \(name) password"
        case .token:
            return "Needs a token from \(name)"
        case nil:
            return nil
        }
    }

    /// iCloud and the mail account take only an app password from another app, made in the
    /// account's own security settings. SIQsermon takes the account's own password.
    var usesAppPassword: Bool {
        id == "icloud" || id == "himalaya"
    }

    /// Why its gateway would not take a sign-in or a sign-out, in one plain line: the app's
    /// own for each rule a refusal names, the gateway's sentence for any other, and the
    /// app's for a failure before the gateway answered.
    func refusal(_ error: Error, assistant: String) -> String {
        guard let shape = error as? GatewayErrorShape, let code = ConnectorRefusalCode(shape) else {
            return ErrorText.describe(error)
        }
        switch code {
        case .signInNotSetUp:
            return "\(name) sign-in is not set up on \(assistant)'s gateway yet."
        case .providerRefused:
            return "\(name) would not finish the sign-in, so nothing changed. Try again."
        case .scopesMissing:
            return "\(name) did not allow all that \(assistant) needs. Sign in again and allow everything."
        case .noSuchAccount:
            return "That \(name) account is no longer linked, so there was nothing to change."
        case .accountIsOnTheBox:
            return "That sign-in is set up on \(assistant)'s computer, so it changes only there."
        case .signature:
            return "Only your own iPhones can change \(assistant)'s connectors."
        case .stale:
            return "Nothing changed, since \(assistant)'s gateway already has a newer change. Try again."
        case .badValue:
            return "What was sent for \(name) could not be used. Check it and try again."
        }
    }
}
