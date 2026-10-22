// Constants for the original Light and Dark rims, also used by the widgets.
import Foundation

struct RimStyle: Equatable, Sendable {
    let light: Double
    let dark: Double
    static let standard = RimStyle(light: 0.75, dark: 0)
    private init(light: Double, dark: Double) { self.light = light; self.dark = dark }
    func rainbow(isDark: Bool) -> Double { isDark ? dark : light }
}
