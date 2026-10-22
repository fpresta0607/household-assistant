// The operator scopes this app asks for.
//
// Chat, identity, history and the assistant's settings need read and write, and that is
// all the phone ever asks for.

import Foundation

enum OperatorScope {
    static let read = "operator.read"
    static let write = "operator.write"

    static let chat = [read, write]
}
