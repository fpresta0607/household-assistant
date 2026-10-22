// A socket that replays captured frames instead of touching the network.
//
// Its state is the main actor's, where the tests script it. The connection calls a socket
// from away from the main actor too, so each call hops here first.

import Foundation
@testable import HouseholdAssistant

@MainActor
final class ScriptedTransport: GatewayTransport {
    struct Closed: Error {}

    private(set) var openCount = 0
    private(set) var requests: [GatewayRequest] = []
    /// How many frames the connection has read, and how many of those it read from the
    /// main thread, which should be none.
    private(set) var reads = 0
    private(set) var readsOnMainThread = 0
    /// Runs on every open; a test pushes the challenge from here.
    var onOpen: ((ScriptedTransport) -> Void)?
    /// Runs on every request the connection sends; a test answers from here.
    var onRequest: ((ScriptedTransport, GatewayRequest) -> Void)?

    private var isOpen = false
    private var inbox: [String] = []
    private var waiting: CheckedContinuation<String, Error>?

    nonisolated func open(_ url: URL) async throws {
        await opened()
    }

    nonisolated func send(_ text: String) async throws {
        try await sent(text)
    }

    nonisolated func receive() async throws -> String {
        try await nextFrame(isOnMainThread: Self.isOnMainThread())
    }

    /// The connection closes from the main actor.
    nonisolated func close() {
        MainActor.assumeIsolated {
            closed()
        }
    }

    func push(_ text: String) {
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: text)
        } else {
            inbox.append(text)
        }
    }

    /// The far end hangs up.
    func drop() {
        closed()
    }

    private func opened() {
        openCount += 1
        isOpen = true
        onOpen?(self)
    }

    private func sent(_ text: String) throws {
        guard isOpen else {
            throw Closed()
        }
        let request = try JSONDecoder().decode(GatewayRequest.self, from: Data(text.utf8))
        requests.append(request)
        onRequest?(self, request)
    }

    private func nextFrame(isOnMainThread: Bool) async throws -> String {
        reads += 1
        if isOnMainThread {
            readsOnMainThread += 1
        }
        if !inbox.isEmpty {
            return inbox.removeFirst()
        }
        guard isOpen else {
            throw Closed()
        }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    private func closed() {
        isOpen = false
        inbox = []
        waiting?.resume(throwing: Closed())
        waiting = nil
    }

    /// Synchronous, because asking which thread this is has no meaning in async code.
    nonisolated private static func isOnMainThread() -> Bool {
        Thread.isMainThread
    }
}
