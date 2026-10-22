// How Account shows one of the person's iPhones: its model as Apple writes it, the SF
// Symbol that draws it, and when the gateway last saw it. A phone that gave no model is
// an iPhone, since this app runs on nothing else.

import Foundation

extension PairedPhone {
    private var isIPad: Bool {
        model?.lowercased() == "ipad"
    }

    var modelName: String {
        isIPad ? "iPad" : "iPhone"
    }

    var symbol: String {
        isIPad ? "ipad" : "iphone"
    }

    var lastSeen: Date? {
        lastSeenAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}
