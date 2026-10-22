// The one word the gateway gives a model worth noticing in the picker.

import Foundation

enum ModelBadge: String, Decodable, Sendable {
    case fast, smart, free

    var label: String {
        rawValue.uppercased()
    }
}
