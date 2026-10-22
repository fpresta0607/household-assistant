// This phone's own assistant as its gateway holds it, for Settings and the assistant's
// page: who it is, its voice, how it talks, its model and connectors, this phone's
// notifications, the models it could use instead, and the household's spend this month,
// kept across launches so the Spend page opens on the last month at once.
//
// Every change is signed with this phone's device key, as a location report is, and sent
// to this phone's own gateway, which takes it only from its own person's phones. While a
// change is on its way its row shows the new value with a spinner. The gateway answers
// with what it read back from its config, and that is what the row shows next: when it
// refuses, the row springs back to what the gateway holds and says why in one line.
//
// A connector's sign-in goes the same way, signed on the same clock, since the gateway's
// replay guard is shared: a provider's code, with its verifier when it takes PKCE, an app
// password or a token, straight to the gateway and never kept here, with the account it
// replaces for Switch account. Its row shows a spinner while it goes, then the accounts
// the gateway lists, or why it would not in one line.
//
// A voice's sample is spoken by the gateway, against Talk's daily ceiling, so each one is
// asked for once and kept for the rest of the run.

import Foundation
import Observation

@MainActor
@Observable
final class AssistantSettingsModel {
    /// Nil until the gateway has answered.
    private(set) var current: AssistantSettings?
    /// OpenRouter's models the assistant can answer with, in the gateway's order.
    private(set) var models: [OpenRouterModel] = []
    private(set) var spend: SpendReport?
    private(set) var isLoadingSpend = false
    /// A failed refresh keeps the saved report, but must not make it look current.
    private(set) var spendErrorText: String?
    /// Values sent and not yet answered, by field.
    private(set) var pending: [SettingsField: String] = [:]
    /// Connectors whose sign-in or sign-out is on its way to the gateway, by id.
    private(set) var signingIn: Set<String> = []
    /// The last change the gateway refused, a connector's sign-in included. The next
    /// change clears it.
    private(set) var refusal: SettingsRefusal?
    /// Why the settings could not be read, in the gateway's words.
    private(set) var errorText: String?
    /// Why the last sample could not be spoken, such as Talk's daily ceiling.
    private(set) var sampleRefusal: String?
    /// Samples already spoken, by voice and words.
    private var samples: [SampleKey: RoomMedia] = [:]

    private struct SampleKey: Hashable {
        let text: String
        let voice: String
    }

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let sign: (String) throws -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let spendStore: SpendStore?
    /// When the newest change was signed: the gateway takes only a newer one.
    @ObservationIgnored private var lastChangeAt = 0
    @ObservationIgnored private var spendRequestID: UUID?

    /// `spendStore` keeps the last month across launches; the tests keep none.
    init(
        connection: GatewayConnection,
        sign: @escaping (String) throws -> String,
        now: @escaping () -> Date = Date.init,
        spendStore: SpendStore? = nil
    ) {
        self.connection = connection
        self.sign = sign
        self.now = now
        self.spendStore = spendStore
        spend = spendStore?.spendReport
    }

    // MARK: - Reading

    func load() async {
        do {
            current = try await connection.assistantSettings()
            errorText = nil
        } catch {
            errorText = ErrorText.describe(error)
        }
    }

    /// Keeps the last list when the gateway cannot be asked.
    func loadModels() async {
        if let list = try? await connection.openRouterModels() {
            models = list
        }
    }

    /// Keeps the last report on failure and never replaces it with an older snapshot.
    /// The request identity also prevents an answer arriving after re-pairing from
    /// restoring the previous household's spend.
    func loadSpend() async {
        guard !isLoadingSpend, !Task.isCancelled else { return }
        let requestID = UUID()
        spendRequestID = requestID
        isLoadingSpend = true
        defer {
            if spendRequestID == requestID {
                isLoadingSpend = false
                spendRequestID = nil
            }
        }
        do {
            let report = try await connection.spend()
            guard spendRequestID == requestID, !Task.isCancelled else { return }
            if let spend, report.at < spend.at {
                spendErrorText = "The latest spend hasn't reached this connection yet. Showing the last update."
                return
            }
            spend = report
            spendStore?.spendReport = report
            spendErrorText = nil
        } catch {
            guard spendRequestID == requestID, !Task.isCancelled else { return }
            spendErrorText = ErrorText.describe(error)
        }
    }

    /// The Spend page owns this task, cancelling it when hidden or backgrounded.
    /// Poll the saved gateway report, not OpenRouter, so this adds no provider calls.
    func watchSpend(sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async {
        while !Task.isCancelled {
            await loadSpend()
            do {
                try await sleep(60)
            } catch {
                return
            }
        }
    }

    /// Pairing with another gateway, or again: a different assistant's settings never carry over.
    func reset() {
        current = nil
        models = []
        spend = nil
        spendRequestID = nil
        isLoadingSpend = false
        spendErrorText = nil
        spendStore?.spendReport = nil
        pending = [:]
        signingIn = []
        refusal = nil
        errorText = nil
        sampleRefusal = nil
        samples = [:]
    }

    // MARK: - What the rows show

    var name: String? {
        pending[.name] ?? current?.assistant.name
    }

    var voice: AssistantVoice? {
        let id = pending[.voice] ?? current?.assistant.voice
        return current?.voices.first { $0.id == id }
    }

    var tone: Int? {
        pending[.tone].flatMap(Int.init) ?? current?.assistant.tone
    }

    var length: AnswerLength? {
        pending[.length].flatMap(AnswerLength.init(rawValue:)) ?? current?.assistant.length
    }

    /// The model in use as OpenRouter's list has it, for its price and badge. Nil until
    /// the list is read.
    var inUse: OpenRouterModel? {
        models.first { $0.id == current?.model.id }
    }

    /// Off while it cannot be used, whatever the gateway's config holds: one waiting for its
    /// person's sign-in shows off, and turning it on signs in.
    func isOn(_ connector: Connector) -> Bool {
        guard connector.isConnected else {
            return false
        }
        return pending[.connector(connector.id)].map { $0 == "on" } ?? connector.isOn
    }

    /// The connectors its gateway lists that stand at `state`, in the gateway's order, except
    /// that Notion leads those not linked yet, the one he asked to link first (CFO notes
    /// section 4). Connectors shows each state in turn, so the connected ones are on top.
    func connectors(_ state: ConnectorState) -> [Connector] {
        let listed = current?.connectors.filter { $0.state == state } ?? []
        guard state != .connected else {
            return listed
        }
        return listed.filter { $0.id == Self.firstToLink } + listed.filter { $0.id != Self.firstToLink }
    }

    static let firstToLink = "notion"

    var connectorsOn: Int {
        current?.connectors.filter { isOn($0) }.count ?? 0
    }

    func notificationChoice(in conversation: RoomConversation) -> NotificationChoice {
        pending[.notifications(conversation)].flatMap(NotificationChoice.init(rawValue:))
            ?? current?.notificationChoice(in: conversation)
            ?? .all
    }

    func isPending(_ field: SettingsField) -> Bool {
        pending[field] != nil
    }

    func isSigningIn(_ connector: Connector) -> Bool {
        signingIn.contains(connector.id)
    }

    /// Why the gateway refused a change to one of `fields`, for the group that shows them.
    func refusal(for fields: [SettingsField]) -> String? {
        refusal.flatMap { fields.contains($0.field) ? $0.reason : nil }
    }

    // MARK: - The model picker

    /// The models the gateway marks as worth noticing, other than the one in use.
    var popularModels: [OpenRouterModel] {
        models.filter { $0.badge != nil && $0.id != current?.model.id }
    }

    /// Every model whose name, company or id has each word of `query`, or the popular ones
    /// while it has none.
    func models(matching query: String) -> [OpenRouterModel] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else {
            return popularModels
        }
        return models.filter { model in
            let haystack = "\(model.name) \(model.company) \(model.id)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The id of the chain's second (1) or third (2) model, a change on its way shown in its
    /// place, or nil for none.
    func fallbackID(_ position: Int) -> String? {
        if let going = pending[.fallbackModel(position)] {
            return going.isEmpty ? nil : going
        }
        let fallbacks = current?.model.fallbacks ?? []
        return fallbacks.indices.contains(position - 1) ? fallbacks[position - 1].id : nil
    }

    /// What the second (1) or third (2) model may be, as `models(matching:)` gives them, but
    /// never one the chain already holds somewhere else, which the gateway would refuse.
    func fallbackChoices(_ position: Int, matching query: String) -> [OpenRouterModel] {
        let elsewhere = Set(([current?.model.id] + [1, 2].filter { $0 != position }.map(fallbackID)).compactMap { $0 })
        return models(matching: query).filter { !elsewhere.contains($0.id) }
    }

    // MARK: - Samples

    /// `text` in `voice`, once it has been spoken.
    func spokenSample(_ text: String, voice: String) -> RoomMedia? {
        samples[SampleKey(text: text, voice: voice)]
    }

    /// `text` spoken in `voice` by this phone's own gateway, or nil when it would not.
    func sample(_ text: String, voice: String) async -> RoomMedia? {
        let key = SampleKey(text: text, voice: voice)
        if let kept = samples[key] {
            return kept
        }
        do {
            let media = try await connection.speak(text, voice: voice)
            samples[key] = media
            sampleRefusal = nil
            return media
        } catch {
            sampleRefusal = ErrorText.describe(error)
            return nil
        }
    }

    // MARK: - Changing

    /// Signs and sends one change, and shows what the gateway reads back.
    func change(_ field: SettingsField, to value: String) async {
        refusal = nil
        pending[field] = value
        let change = SettingsChange(at: nextChangeAt(), field: field, value: value)
        do {
            let signature = try sign(change.signedText)
            current = try await connection.changeSetting(change, signature: signature)
        } catch {
            refusal = SettingsRefusal(field: field, reason: ErrorText.describe(error))
        }
        // A newer change to the same field may already be on its way, and keeps its row.
        if pending[field] == value {
            pending[field] = nil
        }
    }

    // MARK: - Signing a connector in

    /// Signs `connector` in with an app password, a token or a provider's code, and shows
    /// the accounts the gateway lists. With `account`, it is Switch account, and the
    /// gateway forgets that account only once the new one is linked. Nothing of
    /// `credential` is kept.
    func connect(_ connector: Connector, with credential: ConnectorCredential, replacing account: LinkedAccount? = nil) async {
        await send(ConnectorChange(at: nextChangeAt(), connector: connector.id, action: .connect(credential, replacing: account?.id)), for: connector)
    }

    /// Forgets `account`, or with none the connector's own sign-in, as an older gateway
    /// that lists no accounts takes it.
    func disconnect(_ connector: Connector, account: LinkedAccount? = nil) async {
        await send(ConnectorChange(at: nextChangeAt(), connector: connector.id, action: .disconnect(account: account?.id)), for: connector)
    }

    /// A sign-in through `connector`'s provider's page. `browser` shows the page in a sheet
    /// that listens on `callbackScheme` and gives back the provider's answer, or throws
    /// `CancellationError` when the person closes it. `authorization` is nil when this build
    /// cannot open the page: Google's client id is still the placeholder, or the gateway
    /// described a page that is not https.
    func connectOAuth(
        _ connector: Connector,
        replacing account: LinkedAccount? = nil,
        with authorization: OAuthAuthorization?,
        browser: (_ page: URL, _ callbackScheme: String) async throws -> URL
    ) async {
        refusal = nil
        do {
            guard let authorization else {
                throw OAuthSignInFailure.notSetUp(provider: connector.name)
            }
            let answer = try await browser(authorization.url, authorization.callbackScheme)
            let code = try authorization.code(from: answer)
            await connect(connector, with: authorization.credential(code: code), replacing: account)
        } catch is CancellationError {
            // Closed before the provider answered: nothing changed, and there is nothing to say.
        } catch {
            refusal = SettingsRefusal(field: .connector(connector.id), reason: ErrorText.describe(error))
        }
    }

    private func send(_ change: ConnectorChange, for connector: Connector) async {
        refusal = nil
        signingIn.insert(connector.id)
        do {
            let signature = try sign(change.signedText)
            current = try await connection.changeConnector(change, signature: signature)
        } catch {
            let reason = connector.refusal(error, assistant: current?.assistant.name ?? "your assistant")
            refusal = SettingsRefusal(field: .connector(connector.id), reason: reason)
        }
        signingIn.remove(connector.id)
    }

    /// Now, or a millisecond after the last change if the clock has not moved on since.
    private func nextChangeAt() -> Int {
        lastChangeAt = max(Int((now().timeIntervalSince1970 * 1000).rounded()), lastChangeAt + 1)
        return lastChangeAt
    }
}

