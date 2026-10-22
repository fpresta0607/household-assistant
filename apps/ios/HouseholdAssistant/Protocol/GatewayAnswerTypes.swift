// The model each request in flight wants its answer as, by request id.
//
// The connection's reader decodes a frame away from the main actor, and an answer whose
// request said what it wants is read from the frame straight into that model, in the one
// pass that reads the frame, rather than into JSON that is written out and read again.
// The main actor adds a request's model before it sends the request, so the reader always
// finds it, and takes it out once the request is over. Kept under a lock, because the two
// run on different threads.

import Foundation

final class GatewayAnswerTypes: @unchecked Sendable {
    /// Where a decoder finds these: `GatewayCodec.decode` puts them in its `userInfo`. The
    /// key's initializer is failable only in its signature, and makes a key of any name.
    static let userInfoKey = CodingUserInfoKey(rawValue: "GatewayAnswerTypes")!

    private let lock = NSLock()
    private var types: [String: any (Decodable & Sendable).Type] = [:]

    func expect(_ type: any (Decodable & Sendable).Type, for requestId: String) {
        lock.lock()
        defer {
            lock.unlock()
        }
        types[requestId] = type
    }

    func type(for requestId: String) -> (any (Decodable & Sendable).Type)? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return types[requestId]
    }

    func forget(_ requestId: String) {
        lock.lock()
        defer {
            lock.unlock()
        }
        types[requestId] = nil
    }

    func forgetAll() {
        lock.lock()
        defer {
            lock.unlock()
        }
        types = [:]
    }
}
