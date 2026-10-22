// The connection to one gateway: handshake, pairing, requests, events, reconnect.
//
// The state machine runs on the main actor, where the screens read it, and one isolation
// domain keeps it free of races by construction. No frame is read or decoded there. Each
// is taken off the socket and decoded away from the main actor, in one pass, straight into
// the model its request or its event wants, and the main actor is handed the result: a
// streamed reply's every piece and every catch-up page arrive ready to use.

import Foundation
import Observation

@MainActor
@Observable
final class GatewayConnection {
    struct Configuration: Equatable {
        let url: URL
        let client: ClientInfo
        let scopes: [String]
        let locale: String
    }

    private(set) var state: ConnectionState = .disconnected
    /// The session this phone chats in, from `hello-ok`.
    private(set) var mainSessionKey: String?

    @ObservationIgnored var onEvent: ((GatewayEvent) -> Void)?
    /// Runs after every successful handshake, including reconnects.
    @ObservationIgnored var onConnected: (() -> Void)?

    @ObservationIgnored private let transport: GatewayTransport
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let signer: DeviceSigner
    @ObservationIgnored private let sleep: (Double) async throws -> Void
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The wait before the next try, which `retryNow` cuts short.
    @ObservationIgnored private var backoff: Task<Void, Never>?
    @ObservationIgnored private var tickWatcher: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: CheckedContinuation<GatewayResponse.Body, Error>] = [:]
    /// The model each pending request wants its answer as, which the reader reads it into.
    @ObservationIgnored private let answerTypes = GatewayAnswerTypes()
    /// Each pending request's timeout, so it dies with the request instead of
    /// sleeping out its full term after the answer has already arrived.
    @ObservationIgnored private var timeouts: [String: Task<Void, Never>] = [:]
    /// The frame being read and decoded away from the main actor.
    @ObservationIgnored private var reading: Task<GatewayFrame?, Error>?
    @ObservationIgnored private var lastFrameAt = Date()

    static let handshakeTimeoutSeconds: Double = 15
    static let requestTimeoutSeconds: Double = 30

    init(
        transport: GatewayTransport,
        credentials: CredentialStore,
        signer: DeviceSigner,
        sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.signer = signer
        self.sleep = sleep
        self.now = now
    }

    /// A connect is in flight the moment this returns, so a caller with
    /// something to send can see one coming and wait for it.
    func start(_ configuration: Configuration) {
        stop()
        state = .connecting
        runTask = Task { [weak self] in
            await self?.run(configuration)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        backoff?.cancel()
        backoff = nil
        tickWatcher?.cancel()
        tickWatcher = nil
        transport.close()
        failPending(with: GatewayConnectionError.notConnected)
        state = .disconnected
    }

    /// Sends one request and returns its payload as JSON, or throws the gateway's error.
    func request(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        guard case .json(let payload) = try await answer(method, params, as: nil) else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return payload ?? .null
    }

    /// Sends one request and returns its payload as `Answer`, read straight from the frame
    /// away from the main actor, or throws the gateway's error, or why the payload did not
    /// read as `Answer`.
    func request<Answer: Decodable & Sendable>(
        _ method: String,
        _ params: JSONValue = .object([:]),
        as type: Answer.Type
    ) async throws -> Answer {
        switch try await answer(method, params, as: type) {
        case .model(let model as Answer):
            return model
        case .unreadable(let error):
            throw error
        case .model, .json:
            throw GatewayConnectionError.unexpectedFrame
        }
    }

    /// Sends one request and waits for its answer: JSON, or the model `type` it wants.
    private func answer(
        _ method: String,
        _ params: JSONValue,
        as type: (any (Decodable & Sendable).Type)?
    ) async throws -> GatewayResponse.Body {
        guard state == .connected else {
            throw GatewayConnectionError.notConnected
        }
        let request = GatewayRequest(method: method, params: params)
        let text = try GatewayCodec.encode(request)
        // Before the request goes, so the reader knows the model when its answer comes.
        if let type {
            answerTypes.expect(type, for: request.id)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            Task {
                do {
                    try await self.transport.send(text)
                } catch {
                    self.finish(request.id, with: .failure(error))
                }
            }
            timeouts[request.id] = Task {
                try? await Task.sleep(for: .seconds(Self.requestTimeoutSeconds))
                // A cancelled sleep returns rather than throwing here, so the
                // cancellation has to be checked or the timeout still fires.
                guard !Task.isCancelled else {
                    return
                }
                self.finish(request.id, with: .failure(GatewayConnectionError.timedOut))
            }
        }
    }

    // MARK: - The loop

    private func run(_ configuration: Configuration) async {
        var attempt = 0
        while !Task.isCancelled {
            guard let credential = currentCredential() else {
                state = .needsPairing(message: "Pair this phone to get started.")
                return
            }
            if case .pairingPending = state {
                // Keep showing the approval screen between knocks.
            } else {
                state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
            }

            var waitSeconds = ReconnectPolicy.delaySeconds(forAttempt: attempt + 1)
            do {
                let response = try await handshake(configuration, credential: credential)
                if Task.isCancelled {
                    return
                }
                if response.ok, credential.kind == .bootstrapToken {
                    guard try handOff(response) else {
                        state = .needsPairing(message: "That code did not pair this phone. Get a new one.")
                        return
                    }
                    // Paired: back at once as the operator, with the phone's own token.
                    transport.close()
                    continue
                }
                if response.ok {
                    try accept(response)
                    attempt = 0
                    try await receiveUntilClosed()
                } else {
                    let error = response.error ?? GatewayErrorShape(code: "UNKNOWN", message: "connect refused", details: nil)
                    switch ConnectFailure.classify(error) {
                    case .waitForApproval(let requestId):
                        state = .pairingPending(requestId: requestId)
                        waitSeconds = ReconnectPolicy.approvalPollSeconds
                    case .discardDeviceTokenAndPairAgain(let message):
                        credentials.deviceToken = nil
                        state = .needsPairing(message: message)
                        return
                    case .askForNewSetupCode(let message):
                        credentials.bootstrapToken = nil
                        state = .needsPairing(message: message)
                        return
                    case .retryLater:
                        waitSeconds = 30
                    case .stop(let message):
                        state = .failed(message: message)
                        return
                    }
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                attempt += 1
                state = .reconnecting(attempt: attempt)
                waitSeconds = ReconnectPolicy.delaySeconds(forAttempt: attempt)
            }

            transport.close()
            failPending(with: GatewayConnectionError.notConnected)
            let seconds = waitSeconds
            let backoff = Task<Void, Never> { [sleep] in
                _ = try? await sleep(seconds)
            }
            self.backoff = backoff
            await backoff.value
            if self.backoff == backoff {
                self.backoff = nil
            }
        }
    }

    /// Tries again at once instead of waiting out the delay before the next try, which grows
    /// to half a minute: for the moment iOS says the network is back. A link that is up, or
    /// that waits on a person, is left as it is.
    func retryNow() {
        guard case .reconnecting = state else {
            return
        }
        backoff?.cancel()
    }

    private func currentCredential() -> ConnectRequest.Credential? {
        if let stored = credentials.deviceToken {
            return ConnectRequest.Credential(kind: .deviceToken, value: stored.token)
        }
        if let setup = credentials.bootstrapToken, !setup.isEmpty {
            return ConnectRequest.Credential(kind: .bootstrapToken, value: setup)
        }
        return nil
    }

    /// Opens the socket, answers the challenge, and returns the gateway's verdict.
    private func handshake(
        _ configuration: Configuration,
        credential: ConnectRequest.Credential
    ) async throws -> GatewayResponse {
        transport.close()
        // A read still waiting on the socket just closed ends before the next one opens, so
        // it can never take a frame meant for the new one.
        _ = await reading?.result
        try await transport.open(configuration.url)

        // Nothing in the handshake may hang forever: closing the socket makes
        // the pending receive throw, which lands in the reconnect path.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(Self.handshakeTimeoutSeconds))
            self.transport.close()
        }
        defer {
            watchdog.cancel()
        }

        // A setup code's connect pairs the phone as a mobile node with no scopes of
        // its own; every other connect is the operator asking for what it uses.
        let isSettingUp = credential.kind == .bootstrapToken
        let client = isSettingUp ? configuration.client.settingUp : configuration.client
        let role = isSettingUp ? ConnectRequest.setupRole : ConnectRequest.role
        let scopes = isSettingUp ? [] : configuration.scopes

        let challenge = try await nextChallenge()
        let payload = DeviceAuthPayload.v3(
            deviceId: signer.deviceId,
            client: client,
            role: role,
            scopes: scopes,
            signedAtMs: challenge.ts,
            token: credential.value,
            nonce: challenge.nonce
        )
        let request = ConnectRequest.make(
            challenge: challenge,
            client: client,
            role: role,
            scopes: scopes,
            credential: credential,
            device: ConnectRequest.SignedDevice(
                id: signer.deviceId,
                publicKey: signer.publicKey,
                signature: try signer.sign(payload)
            ),
            locale: configuration.locale
        )
        // `hello-ok` is the largest frame there is, so it is read straight into its model.
        answerTypes.expect(HelloOk.self, for: request.id)
        defer {
            answerTypes.forget(request.id)
        }
        try await transport.send(try GatewayCodec.encode(request))

        while true {
            if case .response(let response) = try await handshakeFrame(), response.id == request.id {
                return response
            }
        }
    }

    private func nextChallenge() async throws -> ConnectChallenge {
        while true {
            if case .event(let event) = try await handshakeFrame(), event.event == "connect.challenge", let payload = event.payload {
                return try payload.decoded(as: ConnectChallenge.self)
            }
        }
    }

    /// The next frame of the handshake, where one that does not decode ends the attempt.
    private func handshakeFrame() async throws -> GatewayFrame {
        guard let frame = try await nextFrame() else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return frame
    }

    /// The socket's next frame, read and decoded away from the main actor, which is handed
    /// it ready to use. Nil for a frame this version does not model.
    ///
    /// The read runs detached, so it is never on the main actor, whatever isolation the
    /// build gives a function by default. A run that was stopped reads no more, and the
    /// next one waits for the read in progress to end before it opens a socket.
    private func nextFrame() async throws -> GatewayFrame? {
        try Task.checkCancellation()
        let transport = self.transport
        let answerTypes = self.answerTypes
        let read = Task.detached(priority: Task.currentPriority) {
            let text = try await transport.receive()
            return try? GatewayCodec.decode(text, answerTypes: answerTypes)
        }
        reading = read
        return try await read.value
    }

    /// The `hello-ok` a connect that succeeded answers with.
    private static func hello(in response: GatewayResponse) throws -> HelloOk {
        switch response.body {
        case .model(let hello as HelloOk):
            return hello
        case .unreadable(let error):
            throw error
        case .model, .json:
            throw GatewayConnectionError.unexpectedFrame
        }
    }

    private func accept(_ response: GatewayResponse) throws {
        let hello = try Self.hello(in: response)
        if let token = hello.auth.deviceToken {
            credentials.deviceToken = StoredDeviceToken(token: token)
        }
        mainSessionKey = hello.snapshot.sessionDefaults.mainSessionKey
        lastFrameAt = now()
        state = .connected
        onConnected?()
        watchTicks(everySeconds: Double(hello.policy.tickIntervalMs) / 1000)
    }

    /// Keeps the operator token a setup code's connect hands back beside the node
    /// one, and forgets the setup code, which has done its one job. False when no
    /// operator token came back, which leaves the phone nothing to chat with.
    private func handOff(_ response: GatewayResponse) throws -> Bool {
        let hello = try Self.hello(in: response)
        credentials.bootstrapToken = nil
        guard let issued = hello.auth.deviceTokens?.first(where: { $0.role == ConnectRequest.role }) else {
            return false
        }
        credentials.deviceToken = StoredDeviceToken(token: issued.deviceToken)
        return true
    }

    private func receiveUntilClosed() async throws {
        while !Task.isCancelled {
            let frame = try await nextFrame()
            lastFrameAt = now()
            switch frame {
            case .response(let response)?:
                if response.ok {
                    finish(response.id, with: .success(response.body))
                } else {
                    let error = response.error ?? GatewayErrorShape(code: "UNKNOWN", message: "request failed", details: nil)
                    finish(response.id, with: .failure(error))
                }
            case .event(let event)?:
                onEvent?(event)
            case .request?:
                break
            case nil:
                // A frame this version does not model is skipped, not fatal.
                break
            }
        }
    }

    /// The gateway sends `tick` on a fixed interval. Silence for well over two
    /// intervals means a dead link that TCP has not noticed yet.
    ///
    /// Only silence the app was awake to hear counts. iOS suspends an app in the
    /// background, so a watcher that wakes well after it asked has just come
    /// back, with what the gateway sent meanwhile still unread in the socket.
    /// Judged by the clock alone, it would drop a live link on every return to
    /// the app after a minute or so away. The silence counts from that wake
    /// instead. "Well after" is more than half an interval late: a live link
    /// had a tick at most an interval before the last look, so the silence at
    /// the next wake is at most two intervals and its lateness, and up to half
    /// an interval late it cannot pass the limit.
    private func watchTicks(everySeconds interval: Double) {
        tickWatcher?.cancel()
        tickWatcher = nil
        guard interval > 0 else {
            return
        }
        let started = now()
        tickWatcher = Task { [weak self] in
            var lookedAt = started
            var listeningSince = started
            while let self, !Task.isCancelled, self.state == .connected {
                try? await Task.sleep(for: .seconds(interval))
                let moment = self.now()
                if moment.timeIntervalSince(lookedAt) > interval * 1.5 {
                    listeningSince = moment
                }
                lookedAt = moment
                if !Task.isCancelled, self.state == .connected,
                   moment.timeIntervalSince(max(self.lastFrameAt, listeningSince)) > interval * 2.5 {
                    self.transport.close()
                    return
                }
            }
        }
    }

    private func finish(_ id: String, with result: Result<GatewayResponse.Body, Error>) {
        answerTypes.forget(id)
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPending(with error: Error) {
        let waiting = pending
        pending = [:]
        answerTypes.forgetAll()
        for timeout in timeouts.values {
            timeout.cancel()
        }
        timeouts = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }
}
