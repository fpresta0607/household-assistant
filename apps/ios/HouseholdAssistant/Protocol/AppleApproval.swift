// What the approver's phone signs to let one phone that signed in with Apple in as one
// person, exactly as deploy/openclaw/plugins/household-app/apple-signin.js builds it.
//
// The other gateway hears the approval only over the relay, so the signature, made with
// the key this phone pairs with, is how it knows the approver's own phone said yes.

import Foundation

enum AppleApproval {
    static let version = "household-app/apple-approve/v1"

    static func signedText(requestId: String, person: String, at: Int) -> String {
        [version, requestId, person, String(at)].joined(separator: "\n")
    }
}
