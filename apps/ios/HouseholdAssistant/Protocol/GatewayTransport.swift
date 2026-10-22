// The socket under the connection.
//
// A protocol because there are two real implementations: URLSession on the
// phone, and a scripted one that replays the captured fixtures in the tests.
//
// It is not bound to the main actor. The connection reads every frame away from the
// main thread, so the socket is called from there as well as from the main actor, and
// each implementation keeps its own state safe to call from either.

import Foundation

protocol GatewayTransport: AnyObject, Sendable {
    func open(_ url: URL) async throws
    func send(_ text: String) async throws
    /// The next text frame. Throws when the socket closes.
    func receive() async throws -> String
    func close()
}
