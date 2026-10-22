// A picked ring as the colour SwiftUI draws, and the picker's colour back as a ring.

import SwiftUI

extension RingColor {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    init(_ resolved: Color.Resolved) {
        self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }
}

extension Optional where Wrapped == RingColor {
    /// The ring to draw: the one picked, or gold.
    var ringColor: Color {
        map(\.color) ?? Palette.gold
    }
}
