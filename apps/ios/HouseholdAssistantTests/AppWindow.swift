#if canImport(UIKit)
// The app's screens in a window of their own in the test host, for the tests that read
// what UIKit made of them: the tab bar controller (ChatTabBarTests) and what VoiceOver
// finds (VoiceOverActionsTests).
//
// SwiftUI builds what VoiceOver reads only while something reads it, which nothing does in
// a test host, so the window found no message at all. `readByAccessibility` turns on what
// UI automation turns on, through the simulator's accessibility library, as snapshot tests
// of accessibility do, until the window closes.

import Darwin
import SwiftUI
import UIKit
import XCTest

@MainActor
final class AppWindow {
    private let window: UIWindow
    /// What accessibility automation was before this window turned it on, to put back.
    private var automationBefore: Int32?

    private typealias AutomationEnabled = @convention(c) () -> Int32
    private typealias SetAutomationEnabled = @convention(c) (Int32) -> Void

    /// Puts `view` on screen, the size of the simulator, and gives it a second to settle.
    /// `readByAccessibility` builds what VoiceOver reads, as when VoiceOver is on.
    static func showing(_ view: some View, readByAccessibility: Bool = false) async throws -> AppWindow {
        let automationBefore = try readByAccessibility ? setAutomation(true) : nil
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let shown = AppWindow(window: window)
        shown.automationBefore = automationBefore
        return shown
    }

    private init(window: UIWindow) {
        self.window = window
    }

    func close() {
        window.isHidden = true
        if let automationBefore {
            _ = try? Self.setAutomation(automationBefore != 0)
            self.automationBefore = nil
        }
    }

    /// Turns accessibility automation on or off and answers what it was.
    private static func setAutomation(_ isOn: Bool) throws -> Int32 {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let library = try XCTUnwrap(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW | RTLD_LOCAL), "no accessibility library")
        let isEnabled = unsafeBitCast(try XCTUnwrap(dlsym(library, "_AXSAutomationEnabled")), to: AutomationEnabled.self)
        let setEnabled = unsafeBitCast(try XCTUnwrap(dlsym(library, "_AXSSetAutomationEnabled")), to: SetAutomationEnabled.self)
        let before = isEnabled()
        setEnabled(isOn ? 1 : 0)
        return before
    }

    /// The first view controller of `type` on screen, looking through every child.
    func controller<Controller: UIViewController>(_ type: Controller.Type) -> Controller? {
        Self.controller(type, in: window.rootViewController)
    }

    private static func controller<Controller: UIViewController>(_ type: Controller.Type, in controller: UIViewController?) -> Controller? {
        guard let controller else {
            return nil
        }
        if let found = controller as? Controller {
            return found
        }
        for child in controller.children {
            if let found = self.controller(type, in: child) {
                return found
            }
        }
        return nil
    }

    /// Every element VoiceOver can land on in the window, in the order it reads them.
    func accessibilityElements() -> [NSObject] {
        var found: [NSObject] = []
        Self.collect(window, into: &found)
        return found
    }

    /// An element, or a container read as VoiceOver reads it: by its list of elements, or by
    /// count and index, the form SwiftUI's hosting views and collection views answer in, or
    /// failing both by its subviews.
    private static func collect(_ object: NSObject, into found: inout [NSObject]) {
        if object.isAccessibilityElement {
            found.append(object)
            return
        }
        if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
            elements.forEach { collect($0, into: &found) }
            return
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = object.accessibilityElement(at: index) as? NSObject {
                    collect(element, into: &found)
                }
            }
            return
        }
        if let view = object as? UIView {
            view.subviews.forEach { collect($0, into: &found) }
        }
    }
}
#endif
