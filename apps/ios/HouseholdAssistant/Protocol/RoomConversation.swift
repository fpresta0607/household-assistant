// The app's two conversations on the household-app channel: the family room, which
// both gateways share through the host relay, and this phone's own thread with its
// assistant, which nobody else reads.

import Foundation

enum RoomConversation: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case family
    case direct
}
