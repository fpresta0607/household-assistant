#if canImport(UIKit)
// The charts and the assistant's pictures, for their before and after page: each chart the
// steward-cards skill shows the assistants how to write, and a whole day of hours, as
// Corey's reply in Leo's own thread; a picture Corey made, square and then wide, and the
// square one full screen; and the Model page's Image and Video segments, and Video once
// OpenRouter offers no video model. Every state is drawn light, and dark under its ".dark"
// id.
//
// Drawn as ScreenshotTests draws, into the same build/screenshots and named by the same
// STEWARD_SCREENSHOTS prefixes. That class keeps its drawing to itself, so the few lines of
// it these states need are here too.

import SwiftUI
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class ChartsAndPicturesScreenshots: XCTestCase {
    private var window: UIWindow?

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: ScreenshotTests.directory, withIntermediateDirectories: true)
        FixtureGateway.forgetPersistedState()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        // Leave the host app as clean as each gateway starts.
        FixtureGateway.forgetPersistedState()
    }

    // MARK: - Charts

    func testCharts() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let charts: [(id: String, question: String, answer: String)] = [
            ("charts.weekly", "Chart our grocery spend by week.", RichAnswers.weeklyChart),
            ("charts.thermostat", "Show me the thermostat today as a chart.", RichAnswers.thermostatChart),
            ("charts.day24", "And every hour of it?", RichAnswers.dayChart),
            ("charts.prices", "Put those coffee makers' prices in a chart.", RichAnswers.pricesChart),
            ("charts.schedule", "Graph the kids' practice this week.", RichAnswers.scheduleChart),
            ("charts.months", "Chart this month's spending beside last month's.", RichAnswers.monthsChart),
            // The assistants' own replies from the 17 October proof turns, as they came back.
            ("charts.proof-corey", "Here is what your answers cost each day this week. Put that in a chart.", ProofReplies.corey),
            ("charts.proof-denise", "Look up Chicago's forecast highs for the next five days, then put them in a chart.", ProofReplies.denise),
        ]
        for (id, question, answer) in charts {
            gateway.room.say(question, by: DemoRoom.person, in: .direct)
            gateway.room.say(answer, by: DemoRoom.assistant, in: .direct)
            await gateway.changed()
            try await snap(id) { roomScreen(gateway) }
            try await snap(id + ".dark", dark: true) { roomScreen(gateway) }
        }
    }

    // MARK: - The assistant's pictures

    /// Pictures Corey made, each sent with its width and height, so each is drawn at its own
    /// shape rather than cropped to 4:3, and the square one open full screen.
    func testAssistantPictures() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let room = gateway.room
        let square = room.keep(DemoMedia.scene(.bloom, width: 1024, height: 1024), kind: .photo, mime: "image/jpeg", width: 1024, height: 1024)
        let wide = room.keep(DemoMedia.scene(.hills, width: 1536, height: 1024), kind: .photo, mime: "image/jpeg", width: 1536, height: 1024)

        room.say("Can you make a picture of a flower for Rosa's card?", by: DemoRoom.person, in: .direct)
        room.say("Here it is.", by: DemoRoom.assistant, in: .direct, media: [square])
        await gateway.changed()
        try await snap("pictures.assistant-square") { roomScreen(gateway) }
        try await snap("pictures.assistant-square.dark", dark: true) { roomScreen(gateway) }

        room.say("Now a wide one of green hills for the computer.", by: DemoRoom.person, in: .direct)
        room.say("Here are the hills.", by: DemoRoom.assistant, in: .direct, media: [wide])
        await gateway.changed()
        try await snap("pictures.assistant-wide") { roomScreen(gateway) }
        try await snap("pictures.assistant-wide.dark", dark: true) { roomScreen(gateway) }

        try await snap("pictures.viewer") { MediaViewer(media: square).environment(gateway.model) }
        try await snap("pictures.viewer.dark", dark: true) { MediaViewer(media: square).environment(gateway.model) }
    }

    // MARK: - The Model page's Image and Video segments

    func testModelSegments() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        for kind in [ModelKind.image, .video] {
            for isDark in [false, true] {
                let id = "settings.models.\(kind.rawValue)" + (isDark ? ".dark" : "")
                guard Self.isWanted(id) else {
                    continue
                }
                try await mount(dark: isDark) { settingsPage(ModelPage(kind: kind), gateway) }
                await askedForModels(kind, gateway)
                try await capture(id)
            }
        }

        // OpenRouter offers no video model, so there is none in use and nothing to pick.
        let none = FixtureGateway()
        none.answers["household-app.models"] = { [settings = none.settings] request in
            if request.params["kind"]?.stringValue == "video" {
                return try FixtureGateway.ok(request, .object(["models": .array([])]))
            }
            return try FixtureGateway.ok(request, XCTUnwrap(settings.answer(request)))
        }
        none.answers["household-app.settings"] = { [settings = none.settings] request in
            var answer = try XCTUnwrap(settings.answer(request))
            if case .object(var members) = answer {
                members["videoModel"] = .null
                answer = .object(members)
            }
            return try FixtureGateway.ok(request, answer)
        }
        await none.connect()
        for isDark in [false, true] {
            let id = "settings.models.video-none" + (isDark ? ".dark" : "")
            guard Self.isWanted(id) else {
                continue
            }
            try await mount(dark: isDark) { settingsPage(ModelPage(kind: .video), none) }
            await askedForModels(.video, none)
            try await capture(id)
        }
    }

    /// Waits until the page on screen has asked `gateway` for its `kind` of models, which
    /// the fixture answers at once.
    private func askedForModels(_ kind: ModelKind, _ gateway: FixtureGateway) async {
        await gateway.eventually("\(kind.rawValue) models asked for") {
            gateway.transport.requests.contains { $0.method == "household-app.models" && $0.params["kind"]?.stringValue == kind.rawValue }
        }
    }

    // MARK: - Drawing

    /// Leo's own thread with Corey, as it shows when opened from Chats.
    private func roomScreen(_ gateway: FixtureGateway) -> some View {
        NavigationStack {
            RoomView(conversation: .direct)
        }
        .environment(gateway.model)
    }

    /// A page of Settings as it shows pushed in its stack.
    private func settingsPage(_ page: some View, _ gateway: FixtureGateway) -> some View {
        NavigationStack {
            page
        }
        .environment(gateway.model)
    }

    private func snap<Content: View>(_ id: String, dark: Bool = false, @ViewBuilder _ content: () -> Content) async throws {
        guard Self.isWanted(id) else {
            return
        }
        try await mount(dark: dark, content)
        try await capture(id)
    }

    /// The states this run renders: STEWARD_SCREENSHOTS lists id prefixes, separated by
    /// commas. Unset or empty renders all.
    private static let wantedPrefixes: [String] = (ProcessInfo.processInfo.environment["STEWARD_SCREENSHOTS"] ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    private static func isWanted(_ id: String) -> Bool {
        wantedPrefixes.isEmpty || wantedPrefixes.contains { id.hasPrefix($0) }
    }

    /// Puts the view on screen in a window of its own, the size of the simulator, and gives
    /// SwiftUI a moment to lay it out.
    private func mount<Content: View>(dark: Bool = false, @ViewBuilder _ content: () -> Content) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene,
            "the test host has no window scene"
        )
        window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: content())
        window.makeKeyAndVisible()
        self.window = window
        try await Task.sleep(for: .milliseconds(700))
    }

    /// Draws what is on screen at twice the point size, in eight bits a channel, and keeps
    /// it as a PNG named by its state id.
    private func capture(_ id: String) async throws {
        guard Self.isWanted(id) else {
            return
        }
        let window = try XCTUnwrap(window, "nothing is on screen for \(id)")
        try await Task.sleep(for: .milliseconds(300))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData(), "\(id) did not encode")
        try data.write(to: ScreenshotTests.directory.appendingPathComponent(id + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = id
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
#endif
