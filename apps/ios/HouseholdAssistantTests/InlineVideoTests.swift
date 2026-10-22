#if canImport(UIKit)
import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class InlineVideoTests: XCTestCase {
    func testVideoDisplaysAndFollowsUIKitRowVisibility() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let bytes = DemoMedia.video()
        XCTAssertFalse(bytes.isEmpty)
        let media = gateway.room.keep(bytes, kind: .video, mime: "video/mp4", width: 640, height: 360, durationMs: 2_000)
        let visibility = ThreadRowVisibility()
        let root = UIHostingController(rootView: InlineVideo(media: media, onOpen: {})
            .environment(gateway.model)
            .environment(\.threadRowVisibility, visibility)
            .environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            visibility.isVisible = false
            window.isHidden = true
            window.rootViewController = nil
            FixtureGateway.forgetPersistedState()
        }
        root.view.layoutIfNeeded()
        try await eventually { self.playerLayers(in: root.view.layer).contains { $0.player != nil } }
        let layer = try XCTUnwrap(playerLayers(in: root.view.layer).first { $0.player != nil })
        let player = try XCTUnwrap(layer.player)
        XCTAssertEqual(player.rate, 0, "prefetched rows must not play")
        visibility.isVisible = true
        try await eventually { layer.isReadyForDisplay && player.rate > 0 && player.currentTime().seconds > 0.05 }
        XCTAssertTrue(player.isMuted)
        visibility.isVisible = false
        try await eventually { player.rate == 0 }
        visibility.isVisible = true
        try await eventually { player.rate > 0 }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let shot = XCTAttachment(image: image)
        shot.name = "inline-video-visible-playing"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func playerLayers(in layer: CALayer) -> [AVPlayerLayer] {
        (layer as? AVPlayerLayer).map { [$0] } ?? (layer.sublayers ?? []).flatMap { playerLayers(in: $0) }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Video did not reach the expected playback state")
    }
}
#endif
