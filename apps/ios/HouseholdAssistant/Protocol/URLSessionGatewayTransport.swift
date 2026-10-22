// The real socket: `URLSessionWebSocketTask`.
//
// The main actor opens, sends and closes, and the connection's reader receives away from
// it, so the open socket is kept under a lock rather than by isolation.

#if canImport(Darwin)
import Foundation

final class URLSessionGatewayTransport: GatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    func open(_ url: URL) async throws {
        let task = URLSession.shared.webSocketTask(with: url)
        // `hello-ok` carries a snapshot that outgrows the 1 MiB default.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        _ = replace(with: task)
    }

    func send(_ text: String) async throws {
        guard let task = current else {
            throw GatewayConnectionError.notConnected
        }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task = current else {
            throw GatewayConnectionError.notConnected
        }
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(decoding: data, as: UTF8.self)
        @unknown default:
            throw GatewayConnectionError.notConnected
        }
    }

    func close() {
        replace(with: nil)?.cancel(with: .normalClosure, reason: nil)
    }

    /// The socket open now.
    private var current: URLSessionWebSocketTask? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return task
    }

    /// Puts `next` in the open socket's place, and hands back the one it replaced.
    private func replace(with next: URLSessionWebSocketTask?) -> URLSessionWebSocketTask? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let previous = task
        task = next
        return previous
    }
}
#endif
