// The colour of the ring round an assistant's face, which its person picks on the
// assistant's page with Edit Color. Gold, the assistants' own colour, until they do. One
// choice for each assistant on this phone, kept with the rest of Appearance, and handed to
// the widgets so a widget draws the same ring as the app.
//
// Compiled into the app, the widget and share extensions and the Linux tests.

import Foundation

struct RingColor: Codable, Equatable, Sendable {
    /// Each 0...1, in sRGB.
    let red: Double
    let green: Double
    let blue: Double
}
