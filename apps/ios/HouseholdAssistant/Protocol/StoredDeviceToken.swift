// The device token the gateway issued this phone.

import Foundation

struct StoredDeviceToken: Codable, Equatable, Sendable {
    let token: String
}
