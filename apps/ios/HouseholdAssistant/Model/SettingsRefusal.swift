// A change the gateway would not make, and why, in its own plain sentence.

import Foundation

struct SettingsRefusal: Equatable, Sendable {
    let field: SettingsField
    let reason: String
}
