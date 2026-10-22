#if canImport(UIKit)
// One of the simulator's accessibility settings turned on for the screenshots drawn
// under it, the way the iPhone's Settings turns it on, through the simulator's
// accessibility library, as AppWindow turns on automation. Reduce Transparency and
// Increase Contrast change how iOS draws its own glass and materials, which a view's
// environment cannot ask for. The setting is put back however the drawing ends.
//
// The library names some settings with an "S" after its prefix and some without, and a
// simulator that has neither still draws the pictures: it says so in the log, and only
// what the app itself is told (a trait, for Increase Contrast) changes them.

import Darwin
import UIKit
import XCTest

@MainActor
enum SimulatorAccessibility {
    enum Setting {
        case reduceTransparency
        case increaseContrast

        /// The library's name for it: Reduce Transparency is the background's enhanced
        /// contrast, and Increase Contrast darkens the system's colours.
        fileprivate var name: String {
            switch self {
            case .reduceTransparency:
                return "EnhanceBackgroundContrast"
            case .increaseContrast:
                return "DarkenSystemColors"
            }
        }

        /// What UIKit says once the setting changes, for SwiftUI to read it again.
        fileprivate var changed: Notification.Name {
            switch self {
            case .reduceTransparency:
                return UIAccessibility.reduceTransparencyStatusDidChangeNotification
            case .increaseContrast:
                return UIAccessibility.darkerSystemColorsStatusDidChangeNotification
            }
        }
    }

    private typealias IsEnabled = @convention(c) () -> UInt8
    private typealias SetEnabled = @convention(c) (UInt8) -> Void

    /// Draws `body` with `setting` on where the simulator can turn it on, then puts the
    /// setting back as it was.
    static func with(_ setting: Setting, _ body: () async throws -> Void) async throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard
            let library = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW | RTLD_LOCAL),
            let reading = ["_AXS", "_AX"].lazy.compactMap({ dlsym(library, $0 + setting.name + "Enabled") }).first,
            let switching = ["_AXSSet", "_AXSet"].lazy.compactMap({ dlsym(library, $0 + setting.name + "Enabled") }).first
        else {
            print("screenshots: this simulator cannot turn on \(setting.name); drawn with the app's own reading of it only")
            try await body()
            return
        }
        let isEnabled = unsafeBitCast(reading, to: IsEnabled.self)
        let setEnabled = unsafeBitCast(switching, to: SetEnabled.self)
        let before = isEnabled()
        setEnabled(1)
        NotificationCenter.default.post(name: setting.changed, object: nil)
        defer {
            setEnabled(before)
            NotificationCenter.default.post(name: setting.changed, object: nil)
        }
        try await Task.sleep(for: .milliseconds(500))
        print("screenshots: \(setting.name) on: \(isEnabled() != 0)")
        try await body()
    }
}
#endif
