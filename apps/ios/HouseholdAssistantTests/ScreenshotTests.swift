#if canImport(UIKit)
// Renders every screen and state the app can show, from the captured
// fixtures, and writes one PNG per state to apps/ios/build/screenshots.
//
// Nothing here compares pixels. The PNGs are the evidence, read by a person
// beside the mockups; the test fails only when a state cannot be reached or
// a screen cannot be drawn. The file names are the state ids the review page
// uses.
//
// The family room and the assistant's thread show the demo household from
// DemoRoom, the same family the preview film shows, saying what the approved
// mockups say so each picture can sit beside its mockup. Which states show which
// approved element is kept in the review's state map.
//
// Light is the app's look first, so every state is drawn light and the ".dark"
// states draw the same in dark mode.
//
// Some states need a finger and are left to the phone and the film: the
// keyboard itself, whose place a stand-in of its height takes where a state
// needs the composer raised, and the "Pair this phone again?" and
// "Disconnect Google?" confirmations. So are the system's own screens: the
// photo picker, the camera, the document scanner, the contact picker, Files
// and Quick Look, the Share Sheet, with the family room and the assistant in
// its top row, and Google's sign-in sheet that Connect opens.

import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class ScreenshotTests: XCTestCase {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/screenshots")

    private var window: UIWindow?

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        FixtureGateway.forgetPersistedState()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        // Leave the host app as clean as each gateway starts.
        FixtureGateway.forgetPersistedState()
    }

    // MARK: - Chats

    func testChats() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        try await snap("chats.populated", gateway)
        try await snap("chats.populated.dark", gateway, dark: true)
        try await snap("chats.populated.xxl", gateway, type: .accessibility2)
        gateway.typing("denise", in: .family)
        await gateway.eventually("typing") { !gateway.model.room.typing(in: .family).isEmpty }
        try await snap("chats.typing", gateway)
        gateway.typing("denise", in: .family, active: false)

        // The Settings tab, which your own face on Chats opens as well.
        gateway.model.tab = .settings
        try await snap("chats.settings-tab", gateway)
        try await snap("chats.settings-tab.dark", gateway, dark: true)
        gateway.model.tab = .chats

        let loading = FixtureGateway()
        loading.answers["household-app.history"] = nil
        await loading.connect { $0.identity != nil }
        try await snap("chats.loading", loading)

        let missing = FixtureGateway()
        missing.refuse(
            "household-app.history",
            code: "INVALID_REQUEST",
            message: "unknown method: household-app.history",
            detailCode: "UNKNOWN_METHOD"
        )
        await missing.connect { $0.room.isAvailable == false }
        try await snap("chats.not-available", missing)

        let pending = FixtureGateway()
        pending.answers["connect"] = { try Fixtures.text("connect-refused-pairing-required", answering: $0.id) }
        pending.model.connect()
        await pending.eventually("pairing pending") {
            if case .pairingPending = pending.model.connection.state { return true }
            return false
        }
        try await snap("chats.pairing-pending", pending)

        let connecting = FixtureGateway()
        connecting.offersChallenge = false
        connecting.model.connect()
        try await snap("chats.connecting", connecting)

        let failed = FixtureGateway()
        failed.refuse("connect", code: "INVALID_REQUEST", message: "The gateway refused this token.", detailCode: "SOMETHING_NEW")
        failed.model.connect()
        await failed.eventually("failed") {
            if case .failed = failed.model.connection.state { return true }
            return false
        }
        try await snap("chats.failed", failed)

        let dropped = FixtureGateway()
        await dropped.connect()
        await dropped.dropLink()
        try await snap("chats.reconnecting", dropped)
    }

    // MARK: - The Today card

    func testTodayCard() async throws {
        // Corey's day at a glance above the pins, the demo's day set from now, so the card
        // has something ahead whenever the screenshots are drawn.
        let gateway = FixtureGateway()
        gateway.answers[DemoToday.method] = { try FixtureGateway.ok($0, DemoToday.answer(at: Date())) }
        await gateway.connect { $0.room.isAvailable == true && $0.today.glance != nil }
        try await snap("chats.today", gateway)
        try await snap("chats.today.dark", gateway, dark: true)

        // Seen once today: a slim banner at the top, which opens the whole card again.
        gateway.model.today.markSeen()
        try await snap("chats.today.banner", gateway)
        try await snap("chats.today.banner.dark", gateway, dark: true)
        // Corey's ring picked white: the banner's face wears it, as the card's does (notes
        // section 8), never the default gold.
        gateway.model.settings.assistantRings[DemoRoom.assistant] = RingColor(red: 1, green: 1, blue: 1)
        try await snap("chats.today.banner.ring-white", gateway)
        try await snap("chats.today.banner.ring-white.dark", gateway, dark: true)
        gateway.model.today.open()
        try await snap("chats.today.ring-white", gateway)
        gateway.model.settings.assistantRings = [:]

        // No card: the pins sit at the top, as before.
        let none = FixtureGateway()
        await none.connect()
        try await snap("chats.today.none", none)
    }

    /// The tab bar as one floating pill under Chats, still both tabs once the list has
    /// scrolled the way a finger would, and Settings at the top and at the very end of its
    /// page, where its last row clears the pill (CFO notes section 10).
    func testTabBar() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        for isDark in [false, true] {
            let suffix = isDark ? ".dark" : ""
            // Mounted whatever the run draws, since the scrolled states start from it.
            try await mount(dark: isDark) { RootView().environment(gateway.model) }
            try await capture("chats.tabbar" + suffix)
            try scrollTheList(by: 240)
            try await Task.sleep(for: .milliseconds(700))
            try await capture("chats.tabbar.scrolled" + suffix)
            gateway.model.tab = .settings
            try await Task.sleep(for: .milliseconds(900))
            try await capture("settings.tabbar" + suffix)
            try scrollToTheEnd()
            try await Task.sleep(for: .milliseconds(700))
            try await capture("settings.tabbar.end" + suffix)
            gateway.model.tab = .chats
        }
    }

    /// Each chat opened from its pin on Chats, inside the tabs the way the phone shows it,
    /// with no tab bar under its composer (CFO notes section 8).
    func testChatsOpenWithoutTheTabBar() async throws {
        for conversation in RoomConversation.allCases {
            let id = "room.\(conversation.rawValue).in-tabs"
            guard Self.isWanted(id) else {
                continue
            }
            let gateway = FixtureGateway()
            await gateway.connect()
            try await mount { RootView().environment(gateway.model) }
            gateway.model.path = [conversation]
            try await Task.sleep(for: .seconds(1.5))
            try await capture(id)
        }
    }

    // MARK: - The family room

    func testFamilyRoom() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        try await snap("room.family") { roomScreen(.family, gateway) }
        try await snap("room.family.dark", dark: true) { roomScreen(.family, gateway) }
        try await snap("room.family.xxl", type: .accessibility2) { roomScreen(.family, gateway) }

        gateway.typing("gia", in: .family)
        await gateway.eventually("typing") { !gateway.model.room.typing(in: .family).isEmpty }
        try await snap("room.family.typing") { roomScreen(.family, gateway) }
        gateway.typing("gia", in: .family, active: false)

        // The scene ends the way the mockup does: Gia's heart on Franco's reply, and
        // "Read by Gia" under it.
        try await snap("room.family.read") { roomScreen(.family, gateway) }

        // A long press lifts the photo above the blurred thread, the five tapbacks over it
        // with Franco's heart lit among them. Where it sat comes from the finger on the
        // phone; here it is a place a photo of that size sits.
        let photo = try gateway.message(.family) { $0.media.first?.kind == .photo }
        let photoRow = CGRect(x: 0, y: 380, width: 402, height: 214)
        try await snap("room.family.reactions-lift") { liftedScreen(photo, at: photoRow, gateway) }
        try await snap("room.family.reactions-lift.dark", dark: true) { liftedScreen(photo, at: photoRow, gateway) }
        let line = try gateway.message(.family) { $0.author == "denise" }
        try await snap("room.family.reactions-lift.text") {
            liftedScreen(line, at: CGRect(x: 0, y: 520, width: 402, height: 96), gateway)
        }

        // Another tapback lands on the photo in place of his heart, with its pop.
        try await mount { roomScreen(.family, gateway) }
        await gateway.model.room.react(to: photo.id, with: Tapback.laugh.emoji, in: .family)
        await gateway.changed()
        try await capture("room.family.reaction-tapback")

        let voice = try gateway.message(.family) { $0.media.first?.kind == .voice }
        try await snap("room.family.reply") {
            ZStack(alignment: .bottom) {
                MeshBackground()
                RoomComposer(conversation: .family, replyingTo: .constant(voice))
            }
            .environment(gateway.model)
        }

        let note = try XCTUnwrap(voice.media.first)
        let noteFile = try await gateway.model.media.url(for: note)
        try await mount { roomScreen(.family, gateway) }
        VoiceNotePlayer.shared.speed = .faster
        VoiceNotePlayer.shared.toggle(note.id, at: noteFile)
        try await Task.sleep(for: .milliseconds(1500))
        try await capture("room.family.voice-playing")
        VoiceNotePlayer.shared.stop()
        VoiceNotePlayer.shared.speed = .normal

        let picture = try XCTUnwrap(photo.media.first)
        try await snap("media.photo") {
            MediaViewer(media: picture)
                .environment(gateway.model)
        }

        let slow = FixtureGateway()
        slow.answers["household-app.send"] = nil
        await slow.connect()
        try await mount { roomScreen(.family, slow) }
        Task {
            await slow.model.room.send("On my way, see you in 20", in: .family)
        }
        await slow.eventually("sending") { slow.model.room.family.messages.last?.status == .sending }
        try await capture("room.family.sending")

        let refused = FixtureGateway()
        refused.refuse(
            "household-app.send",
            code: "INVALID_REQUEST",
            message: "The family room did not accept that message.",
            detailCode: "SOMETHING_NEW"
        )
        await refused.connect()
        await refused.model.room.send("Book the car wash for Saturday", in: .family)
        try await snap("room.family.send-failed") { roomScreen(.family, refused) }

        let dropped = FixtureGateway()
        await dropped.connect()
        try await mount { roomScreen(.family, dropped) }
        await dropped.dropLink()
        try await capture("room.family.reconnecting")
    }

    /// Tapbacks from a person and an assistant alike, on the bubbles that end the family
    /// room: Gia's heart and Denise's thumbs up on Franco's answer, at its top left, and
    /// Corey's exclamation marks on Gia's voice note, at its top right. Then his answer
    /// lifted, its badges in the lift and the five tapbacks over it.
    func testTapbacks() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let answer = try gateway.message(.family) { $0.text == DemoRoom.pickUpWords }
        let voice = try gateway.message(.family) { $0.media.first?.kind == .voice }
        gateway.room.react(to: answer.id, by: "denise", with: Tapback.thumbsUp.emoji)
        gateway.room.react(to: voice.id, by: "corey", with: Tapback.emphasis.emoji)
        await gateway.changed()
        try await snap("room.family.tapbacks") { roomScreen(.family, gateway) }
        try await snap("room.family.tapbacks.dark", dark: true) { roomScreen(.family, gateway) }
        try await snap("room.family.tapbacks.xxl", type: .accessibility2) { roomScreen(.family, gateway) }
        let reacted = try gateway.message(.family) { $0.id == answer.id }
        try await snap("room.family.tapbacks-lift") {
            liftedScreen(reacted, at: CGRect(x: 0, y: 600, width: 402, height: 64), gateway)
        }
    }

    /// Franco's own voice note, whose words are heard while it is on screen and unfold
    /// under it.
    func testVoiceNoteTranscript() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let note = gateway.room.keep(DemoMedia.voiceNote(seconds: 4), kind: .voice, mime: "audio/wav", durationMs: 4_000)
        gateway.room.say("", by: DemoRoom.person, media: [note])
        await gateway.changed()
        try await mount { roomScreen(.family, gateway) }
        VoiceNoteTranscripts.shared.remember("On it. Anything else?", for: note.id)
        try await Task.sleep(for: .milliseconds(800))
        try await capture("room.family.voice-transcript")
        // Words already heard are simply there.
        try await snap("room.family.voice-transcript.dark", dark: true) { roomScreen(.family, gateway) }
    }

    // MARK: - Typing and working

    /// While Corey's run uses a tool, the thread says what he is doing: checking the budget
    /// in Franco's own thread, as a line under the question where his typing bubble was,
    /// and searching the web in the family room, in his typing bubble while Denise types
    /// beside him.
    func testWorking() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("Are we on budget this month?", by: DemoRoom.person, in: .direct)
        await gateway.changed()
        gateway.typing(DemoRoom.assistant, in: .direct)
        gateway.toolStarts("pocketpiggies_budget", in: .direct)
        await gateway.eventually("working") { gateway.model.room.activity(in: .direct) == .budget }
        try await snap("room.direct.working") { roomScreen(.direct, gateway) }
        try await snap("room.direct.working.dark", dark: true) { roomScreen(.direct, gateway) }

        gateway.room.say("Denise, what time is the recital? And Corey, is the pool open Saturday?", by: "gia")
        await gateway.changed()
        gateway.typing("denise", in: .family)
        gateway.typing(DemoRoom.assistant, in: .family)
        gateway.toolStarts("web_search", in: .family)
        await gateway.eventually("working in the family room") { gateway.model.room.activity(in: .family) == .webSearch }
        try await snap("room.family.working") { roomScreen(.family, gateway) }
        try await snap("room.family.working.dark", dark: true) { roomScreen(.family, gateway) }
        try await snap("room.family.working.xxl", type: .accessibility2) { roomScreen(.family, gateway) }
    }

    // MARK: - Follow-ups

    /// Corey's answer about tonight, at 4:02 PM as the mockup has it, offers three
    /// follow-ups, which slide in under it one after another.
    func testFollowups() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let asked = gateway.room.minutesAgo(at: 16, 2)
        gateway.room.say("What's on tonight?", by: DemoRoom.person, in: .direct, minutesAgo: asked)
        gateway.room.say(RichAnswers.tonight, by: DemoRoom.assistant, in: .direct, minutesAgo: asked)
        await gateway.changed()
        for (id, isDark) in [("room.direct.followups", false), ("room.direct.followups.dark", true)] {
            try await mount(dark: isDark) { roomScreen(.direct, gateway) }
            // The last chip lands within half a second of the answer showing.
            try await Task.sleep(for: .milliseconds(900))
            try await capture(id)
        }
    }

    // MARK: - Photos, videos, links and files

    func testMedia() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let room = gateway.room
        func photo(_ scene: DemoMedia.Scene, _ width: Int, _ height: Int) -> RoomMedia {
            room.keep(DemoMedia.scene(scene, width: width, height: height), kind: .photo, mime: "image/jpeg", width: width, height: height)
        }

        // One photo at its own shape, six in one message, and one still on its way.
        let loading = RoomMedia(id: String(repeating: "f", count: 64), kind: .photo, mime: "image/jpeg", bytes: 180_000, width: 1200, height: 900)
        let reads = try XCTUnwrap(gateway.answers["household-app.media"])
        gateway.answers["household-app.media"] = { request in
            guard request.params["id"]?.stringValue != loading.id else {
                // Thrown, so this one is never answered and its box keeps shimmering.
                throw CancellationError()
            }
            return try reads(request)
        }
        room.say("", by: "gia", minutesAgo: 9, media: [photo(.hills, 1800, 1150)])
        let six = [photo(.beach, 1600, 1200), photo(.sunset, 1200, 1600), photo(.bloom, 1200, 1200), photo(.hills, 1600, 1200), photo(.beach, 1200, 900), photo(.sunset, 900, 1200)]
        room.say("The beach this morning", by: "gia", minutesAgo: 8, media: six)
        room.say("", by: "gia", minutesAgo: 7, media: [loading])
        await gateway.changed()
        try await snap("room.family.photos") { roomScreen(.family, gateway) }
        try await snap("room.family.photos.light", dark: false) { roomScreen(.family, gateway) }
        try await snap("room.family.photos.dark", dark: true) { roomScreen(.family, gateway) }

        try await snap("media.viewer") {
            MediaViewer(media: six[1]).environment(gateway.model)
        }
        try await snap("media.viewer.light", dark: false) {
            MediaViewer(media: six[1]).environment(gateway.model)
        }

        // A muted video playing where it is, a link unfolded, and a file.
        let clip = room.keep(DemoMedia.video(), kind: .video, mime: "video/mp4", width: 640, height: 360, durationMs: 2_000)
        room.say("", by: "gia", minutesAgo: 4, media: [clip])
        let recipe = try XCTUnwrap(URL(string: "https://example.com/weeknight-pesto-pasta"))
        LinkPreviewStore.shared.keep(
            LinkPreviewStore.Preview(title: "Weeknight pesto pasta", site: "example.com", image: DemoMedia.pestoPicture(), icon: nil),
            for: recipe
        )
        room.say("Can we make this Sunday? \(recipe.absoluteString)", by: "gia", minutesAgo: 3)
        room.say("Here is the permission slip. It needs a signature by Friday.", by: "corey", minutesAgo: 2, media: [room.permissionSlip])
        await gateway.changed()
        try await snap("room.family.media") { roomScreen(.family, gateway) }
        try await snap("room.family.media.light", dark: false) { roomScreen(.family, gateway) }
        try await snap("room.family.media.dark", dark: true) { roomScreen(.family, gateway) }

        try await snap("media.viewer.video") {
            MediaViewer(media: clip).environment(gateway.model)
        }
    }

    // MARK: - The composer

    func testComposer() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        try await snap("composer.drawer") {
            composer(gateway, isDrawerOpen: true)
        }
        try await snap("composer.drawer.light", dark: false) {
            composer(gateway, isDrawerOpen: true)
        }
        try await snap("composer.drawer.dark", dark: true) {
            composer(gateway, isDrawerOpen: true)
        }
        try await snap("composer.mention") {
            composer(gateway, draft: "Can @")
        }
        try await snap("composer.mention.light", dark: false) {
            composer(gateway, draft: "Can @")
        }
        try await snap("composer.mention.dark", dark: true) {
            composer(gateway, draft: "Can @")
        }

        let waiting = [DemoMedia.Scene.beach, .sunset, .bloom].map { scene in
            let data = DemoMedia.scene(scene, width: 1200, height: 900)
            return StagedAttachment(
                attachment: RoomAttachment(data: data, kind: .photo, mime: "image/jpeg", width: 1200, height: 900),
                preview: UIImage(data: data)
            )
        } + [
            StagedAttachment(
                attachment: RoomAttachment(data: DemoMedia.permissionSlip(), kind: .file, mime: "application/pdf", name: "Field trip permission slip.pdf"),
                preview: nil
            ),
        ]
        try await snap("composer.attachments") {
            composer(gateway, draft: "From the beach this morning", staged: waiting)
        }

        // The voice note, the way Telegram's goes. Each state is drawn light and dark.
        let now = Date()
        var holding = VoiceNoteGesture()
        holding.press(at: now.addingTimeInterval(-7))
        holding.drag(x: 0, y: -20)
        var cancelling = VoiceNoteGesture()
        cancelling.press(at: now.addingTimeInterval(-4))
        cancelling.drag(x: -72, y: 0)
        var locked = VoiceNoteGesture()
        locked.press(at: now.addingTimeInterval(-12))
        locked.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        var stopped = locked
        stopped.stop(at: now.addingTimeInterval(-3))
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("voice-screenshot.m4a")
        let states: [(id: String, gesture: VoiceNoteGesture)] = [
            // Seven seconds into holding the big microphone: grown under the finger and
            // rippling, the thread dimmed, the clock and the bars, a shimmering "Slide to
            // cancel", and the lock above with the finger a quarter of the way to it.
            ("composer.hold", holding),
            // Slid most of the way left: the microphone follows the finger, the hint drifts.
            ("composer.cancel-slide", cancelling),
            // Locked: the bin, the send arrow, and the stop to listen back where the lock was.
            ("composer.locked", locked),
            // Stopped to listen back: the bin, play, the note's own bars to scrub, and send.
            ("composer.listen-back", stopped),
        ]
        for state in states {
            for isDark in [false, true] {
                try await snap(state.id + (isDark ? ".dark" : ""), dark: isDark) {
                    composer(gateway, voiceNote: state.gesture, levels: Self.heardLevels, keptNote: kept)
                }
            }
        }
    }

    /// A voice that rises and falls, for the bars a note shows.
    private static let heardLevels = (0..<140).map { index in
        let step = Double(index)
        return 0.2 + 0.6 * abs(sin(step * 0.37)) * (0.55 + 0.45 * abs(cos(step * 0.11)))
    }

    /// The composer on its own over the page, in a state a finger would have put it in.
    private func composer(
        _ gateway: FixtureGateway,
        draft: String = "",
        staged: [StagedAttachment] = [],
        isDrawerOpen: Bool = false,
        isLocationMenuOpen: Bool = false,
        voiceNote: VoiceNoteGesture = VoiceNoteGesture(),
        levels: [Double] = [],
        keptNote: URL? = nil
    ) -> some View {
        ZStack(alignment: .bottom) {
            MeshBackground()
            RoomComposer(
                conversation: .family,
                replyingTo: .constant(nil),
                draft: draft,
                staged: staged,
                isDrawerOpen: isDrawerOpen,
                isLocationMenuOpen: isLocationMenuOpen,
                voiceNote: voiceNote,
                levels: levels,
                keptNote: keptNote
            )
        }
        .environment(gateway.model)
    }

    // MARK: - This phone's own thread

    func testDirectThread() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        try await snap("room.direct") { roomScreen(.direct, gateway) }
        try await snap("room.direct.dark", dark: true) { roomScreen(.direct, gateway) }

        gateway.typing(DemoRoom.assistant, in: .direct)
        await gateway.eventually("typing") { !gateway.model.room.typing(in: .direct).isEmpty }
        try await snap("room.direct.typing") { roomScreen(.direct, gateway) }
        try await snap("room.direct.typing.dark", dark: true) { roomScreen(.direct, gateway) }

        try await mount { roomScreen(.direct, gateway) }
        gateway.stream(
            runId: "run-1",
            in: .direct,
            seq: 1,
            state: "delta",
            delta: "Tonight is pasta. I already moved the dentist to Thursday because"
        )
        await gateway.eventually("streaming") { gateway.model.room.direct.messages.last?.status == .streaming }
        try await capture("room.direct.streaming")

        gateway.stream(runId: "run-1", in: .direct, seq: 2, state: "error")
        await gateway.eventually("reply failed") {
            if case .failed = gateway.model.room.direct.messages.last?.status { return true }
            return false
        }
        try await capture("room.direct.reply-failed")

        let empty = FixtureGateway()
        let selfJSON: JSONValue = .object(["person": .string(DemoRoom.person), "assistant": .string(DemoRoom.assistant)])
        let keys: JSONValue = .object([
            "family": .string(DemoRoom.sessionKeys[.family] ?? ""),
            "direct": .string(DemoRoom.sessionKeys[.direct] ?? ""),
        ])
        empty.answers["household-app.history"] = { request in
            try FixtureGateway.ok(request, .object([
                "messages": .array([]),
                "hasMore": .bool(false),
                "reactions": .object([:]),
                "reads": .array([]),
                "participants": DemoRoom.participants,
                "self": selfJSON,
                "sessionKeys": keys,
            ]))
        }
        empty.answers["household-app.sync"] = { request in
            try FixtureGateway.ok(request, .object([
                "entries": .array([]),
                "rev": .number(0),
                "hasMore": .bool(false),
                "participants": DemoRoom.participants,
                "self": selfJSON,
                "sessionKeys": keys,
            ]))
        }
        await empty.connect()
        try await snap("room.direct.empty") { roomScreen(.direct, empty) }
    }

    // MARK: - The newest above the composer

    /// Corey starts typing while his thread is already on screen, and his typing bubble
    /// rises in just above the composer, never under it: with the keyboard down, and with
    /// the keyboard up, raised once the thread was showing, so the thread has followed both.
    func testTypingStaysAboveTheComposer() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        for isDark in [false, true] {
            for hasKeyboard in [false, true] {
                try await mount(dark: isDark) { roomScreen(.direct, gateway) }
                if hasKeyboard {
                    try raiseKeyboardStandIn()
                    try await Task.sleep(for: .milliseconds(700))
                }
                gateway.typing(DemoRoom.assistant, in: .direct)
                await gateway.eventually("typing") { !gateway.model.room.typing(in: .direct).isEmpty }
                try await Task.sleep(for: .milliseconds(700))
                try await capture("room.direct.typing-follows" + (hasKeyboard ? ".keyboard" : "") + (isDark ? ".dark" : ""))
                gateway.typing(DemoRoom.assistant, in: .direct, active: false)
                await gateway.eventually("typing over") { gateway.model.room.typing(in: .direct).isEmpty }
            }
        }
    }

    // MARK: - Rich answers

    func testRichAnswers() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let answers: [(id: String, question: String, answer: String)] = [
            ("room.direct.card-chart", "How much did we spend on groceries this month?", RichAnswers.groceriesByWeek),
            ("room.direct.card-line", "How has grocery spend moved this year?", RichAnswers.groceriesByMonth),
            ("room.direct.card-checklist", "Set up Saturday for us.", RichAnswers.saturday),
            ("room.direct.card-scripture", "What does John 3:16 say?", RichAnswers.johnThreeSixteen),
            ("room.direct.card-scripture-without-link", "What does John 3:16 say?",
             "```steward-card\n" + #"{"type":"scripture","reference":"John 3:16","translation":"BSB","verses":[{"n":16,"text":"For God so loved the world that He gave His one and only Son, that everyone who believes in Him shall not perish but have eternal life."}]}"# + "\n```"),
            ("room.direct.card-piggies-budget", "How are we doing this month?", RichAnswers.balanceAndBudget),
            ("room.direct.card-piggies-goal", "Where did it go? And how's the beach fund?", RichAnswers.spendingAndGoal),
            ("room.direct.card-unknown", "Will it rain on Saturday?", RichAnswers.forecast),
        ]
        for (id, question, answer) in answers {
            gateway.room.say(question, by: DemoRoom.person, in: .direct)
            gateway.room.say(answer, by: DemoRoom.assistant, in: .direct)
            await gateway.changed()
            try await snap(id) { roomScreen(.direct, gateway) }
            try await snap(id + ".dark", dark: true) { roomScreen(.direct, gateway) }
            if id == "room.direct.card-chart" {
                try await snap("room.direct.card-chart.light", dark: false) { roomScreen(.direct, gateway) }
            }
            if id == "room.direct.card-checklist" {
                let list = try gateway.message(.direct) { $0.text == RichAnswers.saturday }
                await gateway.model.room.tick(ChecklistTick(messageId: list.id, cardId: "shopping", item: 2), isDone: true, in: .direct)
                try await snap("room.direct.card-checklist-ticked") { roomScreen(.direct, gateway) }
            }
        }

        gateway.room.say("Denise, what did the school send?", by: "gia", in: .family)
        gateway.room.say(RichAnswers.schoolEmail, by: "denise", in: .family)
        gateway.room.say("What's the gate code again?", by: DemoRoom.person, in: .family)
        gateway.room.say(RichAnswers.gateCodeAndBottle, by: "denise", in: .family)
        await gateway.changed()
        try await snap("room.family.card-email") { roomScreen(.family, gateway) }
        try await snap("room.family.card-email.dark", dark: true) { roomScreen(.family, gateway) }

        gateway.room.say("Set up Saturday for us.", by: DemoRoom.person, in: .direct)
        await gateway.changed()
        try await mount { roomScreen(.direct, gateway) }
        gateway.stream(runId: "run-cards", in: .direct, seq: 1, state: "delta", delta: RichAnswers.saturdayArriving)
        await gateway.eventually("streaming") { gateway.model.room.direct.messages.last?.status == .streaming }
        try await capture("room.direct.card-arriving")
        gateway.stream(runId: "run-cards", in: .direct, seq: 2, state: "delta", delta: RichAnswers.saturdayGoingOn)
        await gateway.eventually("the card closed") { gateway.model.room.direct.messages.last?.text.hasSuffix("pickup at") == true }
        try await capture("room.direct.card-arrived-streaming")
    }

    /// Franco's list for Friday's trip with the slip ticked, which Corey sees, then a
    /// question he asked by voice and Corey's answer by voice, each with its words under it.
    func testVoiceAnswer() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let room = gateway.room
        room.say(RichAnswers.beforeTheTrip, by: DemoRoom.assistant, in: .direct)
        let question = room.keep(DemoMedia.voiceNote(seconds: 5), kind: .voice, mime: "audio/wav", durationMs: 5_000)
        room.say("", by: DemoRoom.person, in: .direct, media: [question])
        let answer = room.keep(DemoMedia.voiceNote(seconds: 7), kind: .voice, mime: "audio/wav", durationMs: 7_000)
        room.say("", by: DemoRoom.assistant, in: .direct, media: [answer])
        await gateway.changed()
        VoiceNoteTranscripts.shared.remember("Did the school say what time the bus leaves?", for: question.id)
        VoiceNoteTranscripts.shared.remember("The bus leaves at 9:00 and is back by 3:00. I put it on the calendar.", for: answer.id)
        let list = try gateway.message(.direct) { $0.text == RichAnswers.beforeTheTrip }
        await gateway.model.room.tick(ChecklistTick(messageId: list.id, cardId: "before-trip", item: 0), isDone: true, in: .direct)
        for isDark in [false, true] {
            try await snap("room.direct.voice-answer" + (isDark ? ".dark" : ""), dark: isDark) { roomScreen(.direct, gateway) }
        }
    }

    /// Each answer a skill gave wears its badge above the bubble and the skill's own look:
    /// the calendar's royal, web search's source chips, the lists' mint, and in the family
    /// room the parchment of sermons and scripture beside a plain answer. Finance never
    /// shows in the family room, so PocketPiggies is drawn in the owner's own thread only
    /// (room.direct.card-piggies-budget and room.direct.card-piggies-goal).
    func testSkillCards() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("When's the dentist?", by: DemoRoom.person, in: .direct)
        gateway.room.say(RichAnswers.dentist, by: DemoRoom.assistant, in: .direct)
        gateway.room.say("Is the pool open Saturday morning?", by: DemoRoom.person, in: .direct)
        gateway.room.say(RichAnswers.poolHours, by: DemoRoom.assistant, in: .direct)
        gateway.room.say(RichAnswers.beachList, by: DemoRoom.assistant, in: .direct)
        await gateway.changed()
        try await snap("room.direct.skill-cards") { roomScreen(.direct, gateway) }
        try await snap("room.direct.skill-cards.dark", dark: true) { roomScreen(.direct, gateway) }
        try await snap("room.direct.skill-cards.xxl", type: .accessibility2) { roomScreen(.direct, gateway) }

        gateway.room.say("Corey, anything on giving for Sunday?", by: "gia", in: .family)
        gateway.room.say(RichAnswers.loveThatGives, by: DemoRoom.assistant, in: .family)
        gateway.room.say(RichAnswers.philippians, by: DemoRoom.assistant, in: .family)
        gateway.room.say("Corey, can we move movie night?", by: DemoRoom.person, in: .family)
        gateway.room.say("Done. Movie night moved to Saturday.", by: DemoRoom.assistant, in: .family)
        await gateway.changed()
        try await snap("room.family.skill-cards") { roomScreen(.family, gateway) }
        try await snap("room.family.skill-cards.dark", dark: true) { roomScreen(.family, gateway) }
    }

    // MARK: - A text to send

    /// A text Corey drafted for Franco, with who it is for as his Contacts would answer:
    /// one Gia, a choice of two, nobody by that name, Contacts not allowed, then sent. The
    /// tests have no Contacts, so each answer is set on the room as the lookup would set it.
    /// Apple's message sheet is the system's own and is left to the phone.
    func testMessageCard() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("Text Gia that I'm running late", by: DemoRoom.person, in: .direct)
        gateway.room.say(RichAnswers.textGia, by: DemoRoom.assistant, in: .direct)
        await gateway.changed()
        let draft = try gateway.message(.direct) { $0.text == RichAnswers.textGia }
        let card = MessageCard(to: "Gia", text: "Running 10 minutes late, start dinner without me.")
        let gia = MessageContact(id: "c-1", name: "Gia Marlowe", names: ["Gia", "Marlowe"], address: "+1 (317) 555-0142")
        let giaRomano = MessageContact(id: "c-2", name: "Gia Romano", names: ["Gia", "Romano"], address: "gia@romano.example")

        func show(_ change: (inout MessageCardState) -> Void) {
            var state = MessageCardState(card: card)
            change(&state)
            gateway.model.room.messageCards[draft.id] = state
        }

        show { $0.recipient = .one(gia) }
        try await snap("room.direct.card-message") { roomScreen(.direct, gateway) }
        try await snap("room.direct.card-message.dark", dark: true) { roomScreen(.direct, gateway) }
        try await snap("room.direct.card-message.xxl", type: .accessibility2) { roomScreen(.direct, gateway) }
        show { $0.recipient = .several([gia, giaRomano]) }
        try await snap("room.direct.card-message-several") { roomScreen(.direct, gateway) }
        show {
            $0.recipient = .several([gia, giaRomano])
            $0.chosen = giaRomano
        }
        try await snap("room.direct.card-message-chosen") { roomScreen(.direct, gateway) }
        show { $0.recipient = .nobody }
        try await snap("room.direct.card-message-nobody") { roomScreen(.direct, gateway) }
        show { $0.recipient = .noAccess }
        try await snap("room.direct.card-message-no-access") { roomScreen(.direct, gateway) }
        show {
            $0.recipient = .one(gia)
            $0.words = "Running 15 minutes late, start dinner without me. Save me some pasta!"
            $0.finish(.sent)
        }
        try await snap("room.direct.card-message-sent") { roomScreen(.direct, gateway) }
        try await snap("room.direct.card-message-sent.dark", dark: true) { roomScreen(.direct, gateway) }

        // A text that carries an event, as "send Sarah the movie night" drafts it.
        gateway.room.say("Send Sarah the movie night", by: DemoRoom.person, in: .direct)
        gateway.room.say(RichAnswers.movieNightForSarah, by: DemoRoom.assistant, in: .direct)
        await gateway.changed()
        try await snap("room.direct.card-message-event") { roomScreen(.direct, gateway) }
    }

    // MARK: - The household cart and the order

    /// Daisy's cart in the family room, then Franco tapping Ordered after checking out: the
    /// gateway posts the cart as it now stands, which takes the old card's place, and the
    /// order in his own thread. Daisy's order on its way, and an order that strays into the
    /// family room, which is not drawn.
    func testSharedCartAndOrder() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let cartAnswer = try RichAnswers.householdCart()
        gateway.room.say("Corey, add birthday candles to the cart", by: DemoRoom.person, in: .family)
        gateway.room.say(cartAnswer, by: DemoRoom.assistant, in: .family)
        await gateway.changed()
        try await snap("room.family.card-cart") { roomScreen(.family, gateway) }
        try await snap("room.family.card-cart.dark", dark: true) { roomScreen(.family, gateway) }
        try await snap("room.family.card-cart.xxl", type: .accessibility2) { roomScreen(.family, gateway) }

        let cart = try gateway.message(.family) { $0.text == cartAnswer }
        let ordered = try await gateway.model.room.markOrdered(cartIn: cart.id, in: .family)
        XCTAssertEqual(ordered, 4)
        await gateway.changed()
        try await snap("room.family.cart-ordered") { roomScreen(.family, gateway) }
        try await snap("room.family.cart-ordered.dark", dark: true) { roomScreen(.family, gateway) }
        try await snap("room.direct.cart-ordered") { roomScreen(.direct, gateway) }

        let shipped = FixtureGateway()
        await shipped.connect()
        let order = try RichAnswers.householdOrder()
        shipped.room.say("Where's our order?", by: DemoRoom.person, in: .direct)
        shipped.room.say(order, by: DemoRoom.assistant, in: .direct)
        shipped.room.say("Where's our order?", by: "gia", in: .family)
        shipped.room.say(order, by: DemoRoom.assistant, in: .family)
        await shipped.changed()
        try await snap("room.direct.card-order") { roomScreen(.direct, shipped) }
        try await snap("room.direct.card-order.dark", dark: true) { roomScreen(.direct, shipped) }
        try await snap("room.direct.card-order.xxl", type: .accessibility2) { roomScreen(.direct, shipped) }
        try await snap("room.family.card-order-refused") { roomScreen(.family, shipped) }
    }

    // MARK: - A reminder and a passage arriving

    func testReminderAndScripture() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("Remind me to leave for soccer pickup on Saturday at 5:30", by: DemoRoom.person, in: .direct)
        gateway.room.say(RichAnswers.pickupReminder, by: DemoRoom.assistant, in: .direct)
        await gateway.changed()
        try await snap("room.direct.card-reminder") { roomScreen(.direct, gateway) }
        try await snap("room.direct.card-reminder.dark", dark: true) { roomScreen(.direct, gateway) }

        // A passage partway in: verse 16 settled, verse 17 halfway into its place.
        let passage = try XCTUnwrap(StewardCardParser.segments(in: RichAnswers.johnThreeSixteen, isStreaming: false).compactMap { segment -> ScriptureCard? in
            if case .card(let card) = segment, case .scripture(let scripture) = card.content {
                return scripture
            }
            return nil
        }.first)
        for (id, isDark) in [("room.direct.card-scripture-arriving", false), ("room.direct.card-scripture-arriving.dark", true)] {
            try await snap(id, dark: isDark) {
                ZStack {
                    MeshBackground()
                    ScriptureCardView(scripture: passage, isArriving: true, heldVerses: 1.5)
                        .padding(24)
                }
                .environment(gateway.model)
            }
        }
    }

    // MARK: - What it did

    /// Under an answer, a glass chip for each thing its run changed. In Franco's own thread
    /// Corey added an event and set a reminder; in the family room Denise put Gia's flight on
    /// the calendar and Corey put candles on the cart. The skill badge, when an answer has
    /// one, stays above the bubble.
    func testDidChips() async throws {
        // The family room stops before its scene's end, so Denise answers Gia here once.
        let gateway = FixtureGateway(isSceneFinished: false)
        await gateway.connect()
        let today = Calendar.current.startOfDay(for: Date())
        let movieNight = try XCTUnwrap(Calendar.current.date(byAdding: DateComponents(day: 2, hour: 19), to: today))
        let leave = try XCTUnwrap(Calendar.current.date(byAdding: DateComponents(hour: 15, minute: 45), to: today))
        let landing = try XCTUnwrap(Calendar.current.date(byAdding: DateComponents(day: 1, hour: 16, minute: 10), to: today))
        gateway.room.say("Put movie night on the calendar for 7, and remind me to leave for pickup at 3:45", by: DemoRoom.person, in: .direct)
        gateway.room.say(
            "Done. Movie night is on the family calendar, and I will remind you at 3:45 to leave for pickup \u{23F0}",
            by: DemoRoom.assistant,
            in: .direct,
            did: [
                DemoRoom.change("event", "added", title: "Movie night", at: movieNight),
                DemoRoom.change("reminder", "added", title: "Leave for soccer pickup", at: leave),
            ]
        )
        gateway.room.say("Denise, my flight lands tomorrow at 4:10. Can you put it on the calendar?", by: "gia")
        gateway.room.say(
            "Gia's flight lands at 4:10. I put it on the family calendar \u{2708}\u{FE0F}",
            by: "denise",
            did: [DemoRoom.change("event", "added", title: "Gia lands", at: landing)]
        )
        gateway.room.say("Corey, add birthday candles to the cart", by: DemoRoom.person)
        gateway.room.say(
            "Done. Birthday candles are on the cart \u{1F382}",
            by: DemoRoom.assistant,
            did: [DemoRoom.change("list", "added", title: "Birthday candles")]
        )
        await gateway.changed()
        for isDark in [false, true] {
            let suffix = isDark ? ".dark" : ""
            try await snap("room.direct.did-chips" + suffix, dark: isDark) { roomScreen(.direct, gateway) }
            try await snap("room.family.did-chips" + suffix, dark: isDark) { roomScreen(.family, gateway) }
        }
    }

    // MARK: - Corey at work

    /// While Corey works, each thing it does is a line under the question, spinning and
    /// then ticked; the shopping list it read is a card, the five items the mockup lists;
    /// and a step that waits for Franco's yes is a card with Deny and Approve that turns
    /// into what became of it. How the lines tick and the cards rise and unfold is left to
    /// the film.
    func testCoreyAtWork() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("Plan Saturday for us. Groceries, and the soccer pickup.", by: DemoRoom.person, in: .direct)
        await gateway.changed()
        try await mount { roomScreen(.direct, gateway) }

        // While Corey works, the typing bubble says what he is doing. No step ever stays in
        // the thread: once he answers, only the reply is there.
        gateway.toolStep("start", "exec", call: "call-1", runId: "run-saturday", command: "gog calendar events --saturday")
        gateway.typing(DemoRoom.assistant, in: .direct)
        await gateway.eventually("working") { gateway.model.room.activity(in: .direct) == .calendar }
        try await capture("room.direct.at-work")

        gateway.toolStep("result", "exec", call: "call-1", runId: "run-saturday")
        gateway.typing(DemoRoom.assistant, in: .direct, active: false)
        gateway.room.say(RichAnswers.shoppingList, by: DemoRoom.assistant, in: .direct)
        gateway.stream(runId: "run-saturday", in: .direct, seq: 1, state: "final")
        await gateway.changed()
        await gateway.eventually("done") { gateway.model.room.activity(in: .direct) == nil }
        try await capture("room.direct.tool-reply")
        try await snap("room.direct.tool-reply.dark", dark: true) { roomScreen(.direct, gateway) }

        gateway.room.askApproval("Add to the family calendar", detail: "Soccer pickup, Saturday 5:45 to 6:15 PM\nFamily calendar, reminder at 5:30")
        await gateway.changed()
        try await snap("room.direct.approval") { roomScreen(.direct, gateway) }
        try await snap("room.direct.approval.dark", dark: true) { roomScreen(.direct, gateway) }
        try await snap("room.direct.approval.xxl", type: .accessibility2) { roomScreen(.direct, gateway) }

        try await mount { roomScreen(.direct, gateway) }
        let event = try gateway.message(.direct) { $0.approval != nil }
        await gateway.model.room.answer(event, with: .approve)
        await gateway.changed()
        try await capture("room.direct.approval-approved")

        gateway.room.askApproval("Run a command", detail: "gog calendar delete --event 'Movie night'", isCommand: true)
        await gateway.changed()
        try await capture("room.direct.approval-command")
        let command = try gateway.message(.direct) { $0.approval?.isCommand == true }
        await gateway.model.room.answer(command, with: .deny)
        await gateway.changed()
        try await capture("room.direct.approval-denied")

        let late = gateway.room.askApproval("Set a reminder", detail: "Leave for soccer, Saturday at 5:30 PM")
        gateway.room.settleApproval(late.id, as: "expired")
        await gateway.changed()
        try await capture("room.direct.approval-expired")

        gateway.refuse("household-app.approval.answer", code: "INVALID_REQUEST", message: "that approval is no longer waiting", detailCode: "INVALID_REQUEST")
        gateway.room.askApproval("Share the shopping list with Gia", detail: "Shopping list, 5 items")
        await gateway.changed()
        let refused = try gateway.message(.direct) { $0.approval?.title == "Share the shopping list with Gia" }
        await gateway.model.room.answer(refused, with: .approve)
        try await capture("room.direct.approval-refused")
    }

    // MARK: - Talk

    /// Each state is reached by driving the talk's own loop, then drawn over the demo
    /// thread, with the turn before it that the mockup shows above the live one. Talk
    /// itself is not drawn live: it asks for the microphone as it opens.
    /// A call with Corey, as the Phone app draws one, with Speaker and Mute beside End, on
    /// the speaker unless said: calling, then connected and listening, on the earpiece
    /// chosen with the button, and with AirPods in, then
    /// thinking, thinking while a tool runs, Corey speaking, muted, and muted while Corey
    /// finishes what he is saying, then reconnecting, on hold, a failure, today's voice used
    /// up, and the call ended. Then the call bar over Chats with the call left on, the call
    /// kept as one row in Franco's thread, and what was said on it. The stages come from
    /// driving the call's own state as iOS and the gateway would.
    func testCall() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let start = Date()
        let words = "And remind me to bring the slides"

        // Calling: iOS has the call, and its sound and the link are on their way.
        var calling = TalkSession()
        _ = calling.handle(.began)
        try await snap("call.calling") { callScreen(calling, state: CallState(), gateway) }
        try await snap("call.calling.dark", dark: true) { callScreen(calling, state: CallState(), gateway) }

        var listening = TalkSession()
        _ = listening.handle(.began)
        _ = listening.handle(.heard(words, at: start))
        try await snap("call.listening") { callScreen(listening, level: 0.6, gateway) }
        try await snap("call.listening.dark", dark: true) { callScreen(listening, level: 0.6, gateway) }

        // The earpiece chosen with the Speaker button, which is no longer lit.
        let earpiece = CallRouting(isEarpieceChosen: true)
        try await snap("call.earpiece") { callScreen(listening, routing: earpiece, level: 0.6, gateway) }
        try await snap("call.earpiece.dark", dark: true) { callScreen(listening, routing: earpiece, level: 0.6, gateway) }

        // AirPods in: they have the sound, and the button shows them as Audio.
        let airPods = CallAudioRoutes.Device(id: "F0:5C:77:12:34:56-tsco", name: "Franco\u{2019}s AirPods Pro", kind: .bluetooth)
        try await snap("call.audio.airpods") { callScreen(listening, routing: CallRouting(device: airPods), level: 0.6, gateway) }

        var thinking = listening
        _ = thinking.handle(.tick(start.addingTimeInterval(2)))
        try await snap("call.thinking") { callScreen(thinking, gateway) }
        try await snap("call.thinking.dark", dark: true) { callScreen(thinking, gateway) }

        var waiting = thinking
        _ = waiting.handle(.working(.reminder))
        try await snap("call.thinking.tool") { callScreen(waiting, gateway) }

        let reply = "Done. I will remind you at 8:45 to bring the slides. Want me to add the standup too?"
        var speaking = waiting
        _ = speaking.handle(.reply(reply, isFinished: true))
        _ = speaking.handle(.saidSentence)
        try await snap("call.speaking") { callScreen(speaking, level: 0.8, gateway) }
        try await snap("call.speaking.dark", dark: true) { callScreen(speaking, level: 0.8, gateway) }
        try await snap("call.speaking.xxl", type: .accessibility2) { callScreen(speaking, level: 0.8, gateway) }

        var muted = TalkSession()
        _ = muted.handle(.began)
        _ = muted.handle(.muted(true))
        try await snap("call.muted") { callScreen(muted, gateway) }
        try await snap("call.muted.dark", dark: true) { callScreen(muted, gateway) }

        // Muting never cuts Corey off: he finishes, and the call shows him speaking, muted.
        var mutedSpeaking = speaking
        _ = mutedSpeaking.handle(.muted(true))
        try await snap("call.muted.speaking") { callScreen(mutedSpeaking, level: 0.8, gateway) }

        var failed = waiting
        _ = failed.handle(.failed("Allow the microphone for this app in Settings."))
        try await snap("call.failed") { callScreen(failed, gateway) }

        var usedUp = waiting
        _ = usedUp.handle(.reply("Done. I will remind you at 8:45", isFinished: false))
        _ = usedUp.handle(.saidSentence)
        _ = usedUp.handle(.voiceUsedUp)
        try await snap("call.voice-used-up") { callScreen(usedUp, gateway) }

        // The gateway's link down mid-call: the time runs on, and the microphone stays on.
        var reconnecting = Self.connectedCall(secondsIn: 247)
        reconnecting.handle(.link(isUp: false), at: Date())
        try await snap("call.reconnecting") { callScreen(listening, state: reconnecting, gateway) }
        try await snap("call.reconnecting.dark", dark: true) { callScreen(listening, state: reconnecting, gateway) }

        // Held for a phone call Franco took: Corey stops, and goes on after.
        var held = Self.connectedCall(secondsIn: 247)
        held.handle(.held(true), at: Date())
        var heldSpeaking = speaking
        _ = heldSpeaking.handle(.held(true))
        try await snap("call.on-hold") { callScreen(heldSpeaking, state: held, gateway) }

        // Ended: "Call ended" a moment, the buttons at rest, before the screen goes.
        var ended = Self.connectedCall(secondsIn: 247)
        ended.handle(.ended, at: Date())
        var hungUp = speaking
        _ = hungUp.handle(.hungUp)
        try await snap("call.ended") { callScreen(hungUp, state: ended, gateway) }
        try await snap("call.ended.dark", dark: true) { callScreen(hungUp, state: ended, gateway) }

        // The call left on behind the call bar, over Chats, as Chats places it.
        try await snap("call.bar") {
            RootView()
                .callBar(CallBar(state: Self.connectedCall(secondsIn: 247), level: 0.5, onTap: {}))
                .environment(gateway.model)
        }
        try await snap("call.bar.dark", dark: true) {
            RootView()
                .callBar(CallBar(state: Self.connectedCall(secondsIn: 247), level: 0.5, onTap: {}))
                .environment(gateway.model)
        }
        try await snap("call.bar.reconnecting") {
            RootView()
                .callBar(CallBar(state: reconnecting, level: 0, onTap: {}))
                .environment(gateway.model)
        }

        // The call kept as one row in Franco's thread, after what came before it.
        gateway.room.say("What's on tomorrow morning?", by: DemoRoom.person, in: .direct, minutesAgo: 30)
        gateway.room.say("Standup at 9. Then lunch with Gia at 12:30.", by: DemoRoom.assistant, in: .direct, minutesAgo: 29)
        gateway.room.call(lasting: 247, minutesAgo: 2, words: [
            (DemoRoom.person, words),
            (DemoRoom.assistant, reply),
            (DemoRoom.person, "Yes, add the standup."),
            (DemoRoom.assistant, "Added. You will hear from me at 8:45."),
        ])
        await gateway.changed()
        try await snap("room.direct.call-row") { roomScreen(.direct, gateway) }
        try await snap("room.direct.call-row.dark", dark: true) { roomScreen(.direct, gateway) }
        let row = try gateway.message(.direct) { $0.call != nil }
        let call = try XCTUnwrap(row.call)
        try await snap("room.direct.call-transcript") {
            CallTranscriptSheet(call: call, sentAt: row.sentAt).environment(gateway.model)
        }
    }

    // MARK: - Settings

    func testSettings() async throws {
        // Franco's phone with Corey: the demo settings are the approved page's names and
        // numbers, Will's voice, GLM 5.3 Flash, ten connectors on until Franco signs in to
        // iCloud, Google and Notion, and $38.40 in October.
        let gateway = FixtureGateway()
        await gateway.connect()
        try await mount { SettingsView().environment(gateway.model) }
        await gateway.eventually("settings and spend read") {
            gateway.model.assistantSettings.current != nil && gateway.model.assistantSettings.spend != nil
        }
        try await capture("settings.root")
        try await snap("settings.root.dark", dark: true) { SettingsView().environment(gateway.model) }
        try await snap("settings.root.xxl", type: .accessibility2) { SettingsView().environment(gateway.model) }

        try await snap("settings.assistant.own") { settingsPage(AssistantPage(), gateway) }
        try await snap("settings.assistant.own.dark", dark: true) { settingsPage(AssistantPage(), gateway) }
        try await snap("settings.assistant.own.xxl", type: .accessibility2) { settingsPage(AssistantPage(), gateway) }
        // Corey's ring picked rose with Edit Color, on his page and in the sheet it was picked
        // in, then gold again.
        let rose = try XCTUnwrap(RingColorSheet.colors.first { $0.name == "Rose" }?.ring)
        gateway.model.settings.assistantRings[DemoRoom.assistant] = rose
        try await snap("settings.assistant.own.ring-rose") { settingsPage(AssistantPage(), gateway) }
        try await snap("settings.assistant.own.ring-rose.dark", dark: true) { settingsPage(AssistantPage(), gateway) }
        try await snap("settings.assistant.ring-sheet") {
            RingColorSheet(target: .assistant(DemoRoom.assistant), name: "Corey").environment(gateway.model)
        }
        gateway.model.settings.assistantRings = [:]
        // From the top of the family room, Denise as Gia's gateway carries her: nothing to change.
        XCTAssertNotNil(gateway.model.room.peerAssistant, "the sync page carried Denise")
        try await snap("settings.assistant.peer") { settingsPage(PeerAssistantPage(), gateway) }
        try await snap("settings.assistant.peer.dark", dark: true) { settingsPage(PeerAssistantPage(), gateway) }
        // The family room's own page, from the top of the room: its photo, which a tap
        // changes, Message, and the four in it.
        try await snap("settings.family") { settingsPage(FamilyPage(), gateway) }
        try await snap("settings.family.dark", dark: true) { settingsPage(FamilyPage(), gateway) }
        // The Fam's look, the same on both phones (notes section 8): rose round its face, its
        // glow whole over the page, and Custom's night background, each change a line in
        // the room. On a gateway of its own, so the pages after keep the room as it was.
        let fam = FixtureGateway()
        await fam.connect()
        try await fam.model.room.setFamilyColor(rose)
        try await fam.model.room.setFamilyAppearance(.custom, background: .night)
        await fam.changed()
        try await snap("settings.family.look") { settingsPage(FamilyPage(), fam) }
        try await snap("settings.family.look.dark", dark: true) { settingsPage(FamilyPage(), fam) }
        try await snap("settings.family.ring-sheet") {
            RingColorSheet(target: .family, name: FamilyPage.name, family: fam.model.room.familyLook?.ring).environment(fam.model)
        }
        try await snap("room.family.look") { roomScreen(.family, fam) }
        try await snap("chats.family-look", fam)
        // The name or face at the top of a conversation opens the same pages over it, here
        // after Franco asked Corey to sound more relaxed, as the approved page draws it.
        gateway.room.say("Can you sound a bit more relaxed?", by: DemoRoom.person, in: .direct)
        gateway.room.say("Sure. Tap my name up top and pick how I talk, or change my voice.", by: DemoRoom.assistant, in: .direct)
        gateway.room.say("Perfect", by: DemoRoom.person, in: .direct)
        await gateway.changed()
        for isDark in [false, true] {
            try await snap("room.direct.assistant-page" + (isDark ? ".dark" : ""), dark: isDark) {
                NavigationStack { RoomView(conversation: .direct, isAssistantPageOpen: true) }.environment(gateway.model)
            }
        }
        try await snap("room.family.assistant-page") {
            NavigationStack { RoomView(conversation: .family, isAssistantPageOpen: true) }.environment(gateway.model)
        }
        try await snap("settings.voice") { settingsPage(VoicePage(), gateway) }
        try await snap("settings.name") { settingsPage(NamePage(), gateway) }

        // Every connector Corey's gateway has, the connected ones on top, then iCloud, Google
        // and Notion waiting for Franco's sign-in and switched off; Gia's mail account is not
        // listed. Notion's own page, waiting, with Connect and its token's sheet over the list.
        try await snap("settings.connectors") { settingsPage(ConnectorsPage(), gateway) }
        try await snap("settings.connectors.dark", dark: true) { settingsPage(ConnectorsPage(), gateway) }
        let notion = try XCTUnwrap(gateway.model.assistantSettings.current?.connectors.first { $0.id == "notion" })
        XCTAssertEqual(notion.state, .available)
        XCTAssertFalse(gateway.model.assistantSettings.isOn(notion), "off until it is signed in")
        try await snap("settings.connector.notion") { settingsPage(ConnectorPage(connectorId: "notion"), gateway) }
        try await snap("settings.connectors.token-sheet") {
            settingsPage(ConnectorsPage(signingIn: ConnectorSignInRequest(connector: notion)), gateway)
        }
        try await snap("settings.connectors.token-sheet.dark", dark: true) {
            settingsPage(ConnectorsPage(signingIn: ConnectorSignInRequest(connector: notion)), gateway)
        }
        XCTAssertEqual(gateway.model.assistantSettings.connectors(.unavailable).map(\.id), [], "the app never asks for what this gateway cannot have")

        // Contacts, on this iPhone: on with only the people Franco chose, its own page with
        // everyone shared, only some, and off in the iPhone's Settings, and how to let Corey
        // see the texts some people send. Off, as a new phone has it, is in the list above.
        gateway.model.settings.shouldLookInContacts = true
        gateway.model.permissions.phoneAccess[.contacts] = .limited
        try await snap("settings.connectors.contacts-on") { settingsPage(ConnectorsPage(), gateway) }
        try await snap("settings.contacts.chosen") { settingsPage(ContactsConnectorPage(), gateway) }
        gateway.model.permissions.phoneAccess[.contacts] = .allowed
        try await snap("settings.contacts.all") { settingsPage(ContactsConnectorPage(), gateway) }
        try await snap("settings.contacts.all.dark", dark: true) { settingsPage(ContactsConnectorPage(), gateway) }
        gateway.model.permissions.phoneAccess[.contacts] = .denied
        try await snap("settings.contacts.off-on-iphone") { settingsPage(ContactsConnectorPage(), gateway) }
        try await snap("settings.texts-to-assistant") { settingsPage(ReplyAutomationPage(), gateway) }
        gateway.model.settings.shouldLookInContacts = false
        gateway.model.permissions.phoneAccess = [:]

        try await mount { settingsPage(ModelPage(), gateway) }
        await gateway.eventually("models read") { !gateway.model.assistantSettings.models.isEmpty }
        try await capture("settings.model")
        try await snap("settings.model.dark", dark: true) { settingsPage(ModelPage(), gateway) }
        try await snap("settings.model.second") { settingsPage(FallbackModelPage(position: 1), gateway) }
        try await snap("settings.model.third.dark", dark: true) { settingsPage(FallbackModelPage(position: 2), gateway) }

        try await snap("settings.spend") { settingsPage(SpendPage(), gateway) }
        try await snap("settings.spend.dark", dark: true) { settingsPage(SpendPage(), gateway) }
        try await snap("settings.account") { settingsPage(AccountPage(), gateway) }
        // What iOS has for everything Account mirrors, each in its own words.
        let permissions = gateway.model.permissions
        permissions.statuses = [.notifications: .allowed, .voice: .allowed, .location: .allowed]
        permissions.phoneAccess = [.contacts: .allowed, .photos: .notAsked, .camera: .denied, .faceID: .allowed]
        try await snap("settings.account.iphone-access") { settingsPage(AccountPage(), gateway) }
        try await snap("settings.notifications") { settingsPage(NotificationsPage(), gateway) }
        // iOS has the last word: notifications off in the iPhone's Settings, or delivered quietly.
        permissions.statuses[.notifications] = .denied
        try await snap("settings.notifications.off-on-iphone") { settingsPage(NotificationsPage(), gateway) }
        permissions.statuses[.notifications] = .allowed
        permissions.isDeliveredQuietly = true
        try await snap("settings.notifications.quiet") { settingsPage(NotificationsPage(), gateway) }
        permissions.isDeliveredQuietly = false
        permissions.statuses = [:]
        permissions.phoneAccess = [:]
        try await snap("settings.notifications.not-asked") { settingsPage(NotificationsPage(), gateway) }
        let settings = gateway.model.settings
        try await snapTopAndEnd("settings.appearance") { settingsPage(AppearancePage(), gateway).phonePreferences(settings) }
        settings.theme = .spring
        try await snapTopAndEnd("settings.appearance.seasonal") { settingsPage(AppearancePage(), gateway).phonePreferences(settings) }
        try await snapTopAndEnd("settings.appearance.seasonal.xxl", type: .accessibility2) {
            settingsPage(AppearancePage(), gateway).phonePreferences(settings)
        }
        settings.revertAppearance()
        try await snap("settings.accessibility") { settingsPage(AccessibilityPage(), gateway) }
        try await snap("settings.accessibility.dark", dark: true) { settingsPage(AccessibilityPage(), gateway) }
        // Bold Text on in the iPhone's own Settings bolds the app whatever its switch says.
        permissions.isTextBoldOnIPhone = true
        try await snap("settings.accessibility.bold-on-iphone") { settingsPage(AccessibilityPage(), gateway) }
        permissions.isTextBoldOnIPhone = false
        try await snap("settings.privacy") { settingsPage(PrivacyPage(), gateway) }
        try await snap("settings.privacy.dark", dark: true) { settingsPage(PrivacyPage(), gateway) }
        // Face ID and Contacts said no to in the iPhone's Settings, and an iPhone with no passcode.
        permissions.phoneAccess[.faceID] = .denied
        permissions.phoneAccess[.contacts] = .denied
        try await snap("settings.privacy.off-on-iphone") { settingsPage(PrivacyPage(), gateway) }
        permissions.phoneAccess[.faceID] = .unavailable
        permissions.phoneAccess[.contacts] = .allowed
        try await snap("settings.privacy.no-passcode") { settingsPage(PrivacyPage(), gateway) }
        permissions.phoneAccess = [:]
        // Require Face ID on, with when it asks again under it, and the app as it opens
        // locked: the mark on the glass and nothing of the app.
        gateway.model.settings.isAppLockOn = true
        try await snap("settings.privacy.app-lock") { settingsPage(PrivacyPage(), gateway) }
        let locked = AppCover(settings: gateway.model.settings)
        try await snap("cover.locked") { AppCoverView(cover: locked) }
        try await snap("cover.locked.dark", dark: true) { AppCoverView(cover: locked) }
        gateway.model.settings.isAppLockOn = false
        gateway.model.settings.textSize = .xLarge
        try await snap("settings.text-size") { settingsPage(TextSizePage(), gateway) }
        gateway.model.settings.textSize = .likeIPhone

        // A change landing: the switch flips at once with a spinner while the gateway has it.
        let slow = FixtureGateway()
        slow.answers["household-app.settings.change"] = nil
        await slow.connect()
        await slow.model.assistantSettings.load()
        try await mount { settingsPage(ConnectorsPage(), slow) }
        Task {
            await slow.model.assistantSettings.change(.connector("outlook"), to: "off")
        }
        await slow.eventually("change sent") { slow.model.assistantSettings.isPending(.connector("outlook")) }
        try await capture("settings.change.pending")

        // A refusal: the slider springs back to where Corey's gateway holds it, and says why.
        let refused = FixtureGateway()
        refused.refuse(
            "household-app.settings.change",
            code: "INVALID_REQUEST",
            message: "Only Franco's iPhone can change Corey.",
            detailCode: "SETTINGS_NOT_OWNER"
        )
        await refused.connect()
        try await mount { settingsPage(AssistantPage(), refused) }
        await refused.eventually("settings read") { refused.model.assistantSettings.current != nil }
        await refused.model.assistantSettings.change(.tone, to: "90")
        XCTAssertEqual(refused.model.assistantSettings.tone, 64, "springs back")
        try await capture("settings.change.refused")

        let waitingForGateway = FixtureGateway()
        waitingForGateway.answers["household-app.settings"] = nil
        await waitingForGateway.connect()
        try await snap("settings.assistant.loading") { settingsPage(AssistantPage(), waitingForGateway) }

        let pending = FixtureGateway()
        pending.answers["connect"] = { try Fixtures.text("connect-refused-pairing-required", answering: $0.id) }
        pending.model.connect()
        await pending.eventually("pairing pending") {
            if case .pairingPending = pending.model.connection.state { return true }
            return false
        }
        try await snap("settings.pairing-pending") { SettingsView().environment(pending.model) }

        // Franco's phone, with Gia's new iPhone waiting for him since two minutes ago, named
        // as the gateway names a phone that gave no name.
        let approver = FixtureGateway()
        let asked = ((Date().timeIntervalSince1970 - 120) * 1000).rounded()
        approver.answers["household-app.apple.waiting"] = { request in
            try FixtureGateway.ok(request, .object(["waiting": .array([
                .object(["id": .string("gia-req-1"), "name": .string("A new iPhone"), "at": .number(asked), "person": .string("gia")]),
            ])]))
        }
        await approver.connect()
        try await mount { settingsPage(AccountPage(), approver) }
        await approver.eventually("waiting list read") { !approver.model.signInApprovals.waiting.isEmpty }
        try await capture("settings.waiting-to-join")
        // Settings has no Account row, so the card at the top, the way into Account, counts
        // the iPhone waiting for him.
        try await snap("settings.root.waiting") { SettingsView().environment(approver.model) }

        // The circular crop, over a made-up photo: a warm gradient, wider than tall.
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
            let colors = [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1200, y: 800), options: [])
        }
        try await snap("settings.face-crop") { FaceCropView(image: photo, name: "Corey") { _ in } }
        try await snap("settings.face-crop.zoomed") {
            FaceCropView(image: photo, name: "Corey", scale: 2.5, offset: CGSize(width: 140, height: -90)) { _ in }
        }

        let linked = FixtureGateway()
        linked.model.settings.hasLinkedAppleID = true
        await linked.connect()
        try await snap("settings.apple-linked") { settingsPage(AccountPage(), linked) }
    }

    /// The Spend page with October in full, as it reads on the 31st: the household's total
    /// rising from zero on the 1st to $79.80 on the 31st, on an axis to $80 just above it,
    /// the lines for Corey, Denise and the rest of the key under it, then the 24th tapped,
    /// its date and the total by then under the graph. settings.spend is the demo's October,
    /// which reaches only the 15th, with the days still to come left empty.
    func testSpendMonth() async throws {
        let gateway = FixtureGateway()
        gateway.answers["household-app.spend"] = { try FixtureGateway.ok($0, Self.fullOctober) }
        await gateway.connect()
        await gateway.model.assistantSettings.load()
        await gateway.model.assistantSettings.loadSpend()
        XCTAssertEqual(gateway.model.assistantSettings.spend?.days.count, 31)

        try await snap("settings.spend.full-month") { settingsPage(SpendPage(), gateway) }
        try await snap("settings.spend.full-month.dark", dark: true) { settingsPage(SpendPage(), gateway) }
        try await snap("settings.spend.full-month.day-shown") { settingsPage(SpendPage(shownDay: "2026-10-24"), gateway) }
    }

    /// What the household's key spent each day of October, $79.80 in all: $49.95 of it
    /// Corey's, $24.60 Denise's and $5.25 the rest.
    private static let fullOctoberAmounts = [
        2.75, 3.18, 1.66, 2.68, 2.10, 2.89, 4.20, 2.54, 1.81, 2.40, 2.83, 2.25, 2.97, 3.55, 2.68, 2.46,
        1.77, 2.32, 3.11, 2.78, 1.99, 1.63, 2.42, 2.87, 2.66, 3.42, 2.15, 1.85, 2.59, 3.03, 2.26,
    ]

    private static let fullOctober: JSONValue = .object([
        "month": .string("2026-10"),
        "at": .number(1_793_509_200_000),
        "total": .number(79.80),
        "days": .array(fullOctoberAmounts.indices.map { index in
            let spent = fullOctoberAmounts[...index].reduce(0, +)
            return .object(["day": .string(String(format: "2026-10-%02d", index + 1)), "spent": .number((spent * 100).rounded() / 100)])
        }),
        "lines": .array([
            .object(["id": .string("corey"), "name": .string("Corey"), "amount": .number(49.95)]),
            .object(["id": .string("denise"), "name": .string("Denise"), "amount": .number(24.60)]),
            .object(["id": .string("other"), "name": .string("Other use of the key"), "amount": .number(5.25)]),
        ]),
        "resetsOn": .string("2026-11-01"),
    ])

    /// Franco's phone signing in: Google connected over the signed call, moved up among the
    /// connected and on its own page with the one account Corey's gateway lists, iCloud's
    /// app password sheet, and Google's sign-in refused by the gateway, in the app's one
    /// line for the rule it names.
    func testConnectorSignIns() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        await gateway.model.assistantSettings.load()
        try await mount { settingsPage(ConnectorsPage(), gateway) }

        let settings = gateway.model.assistantSettings
        let connectors = try XCTUnwrap(settings.current?.connectors)
        let google = try XCTUnwrap(connectors.first { $0.id == "gog" })
        let icloud = try XCTUnwrap(connectors.first { $0.id == "icloud" })
        let authorization = try XCTUnwrap(OAuthAuthorization(
            googleClientId: "123456789012-abc123def456.apps.googleusercontent.com",
            pkce: .fresh(),
            state: "fixture-state"
        ))
        await settings.connectOAuth(google, with: authorization) { _, _ in
            URL(string: "\(authorization.redirectURI)?state=fixture-state&code=fixture-code")!
        }
        let connected = try XCTUnwrap(settings.current?.connectors.first { $0.id == "gog" })
        XCTAssertEqual(connected.state, .connected, "the gateway read it back")
        XCTAssertEqual(connected.linkedAccounts.map(\.email), ["franco@example.com"])
        XCTAssertTrue(settings.connectors(.connected).contains { $0.id == "gog" })
        try await capture("settings.connectors.connected")
        try await snap("settings.connectors.connected.dark", dark: true) { settingsPage(ConnectorsPage(), gateway) }
        try await snap("settings.connector.google") { settingsPage(ConnectorPage(connectorId: "gog"), gateway) }
        try await snap("settings.connector.google.dark", dark: true) { settingsPage(ConnectorPage(connectorId: "gog"), gateway) }

        try await snap("settings.connectors.password-sheet") {
            settingsPage(ConnectorsPage(signingIn: ConnectorSignInRequest(connector: icloud)), gateway)
        }

        // Refused as the household-app plugin refuses, with its rule in details.detailCode.
        let refused = FixtureGateway()
        refused.answers["household-app.connector.connect"] = { request in
            #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"Google refused the sign-in (400, invalid_grant)","details":{"detailCode":"PROVIDER_REFUSED"}}}"#
        }
        await refused.connect()
        await refused.model.assistantSettings.load()
        try await mount { settingsPage(ConnectorsPage(), refused) }
        let refusedGoogle = try XCTUnwrap(refused.model.assistantSettings.current?.connectors.first { $0.id == "gog" })
        await refused.model.assistantSettings.connectOAuth(refusedGoogle, with: authorization) { _, _ in
            URL(string: "\(authorization.redirectURI)?state=fixture-state&code=fixture-code")!
        }
        XCTAssertEqual(
            refused.model.assistantSettings.refusal(for: [.connector("gog")]),
            "Google would not finish the sign-in, so nothing changed. Try again."
        )
        try await capture("settings.connectors.refused")
    }

    /// Connectors from a gateway that only counts each connector's sign-ins: iCloud's one is
    /// a count led by the green dot, in the list and on its own page with Disconnect.
    func testConnectorsFromAnOlderGateway() async throws {
        let older = FixtureGateway()
        older.answers["household-app.settings"] = { try Fixtures.text("household-app-settings-response", answering: $0.id) }
        await older.connect()
        await older.model.assistantSettings.load()
        let icloud = try XCTUnwrap(older.model.assistantSettings.current?.connectors.first { $0.id == "icloud" })
        XCTAssertTrue(icloud.linkedAccounts.isEmpty, "the older gateway lists no accounts")
        XCTAssertEqual(icloud.connectedWords, "1 account")
        try await snap("settings.connectors.older-gateway") { settingsPage(ConnectorsPage(), older) }
        try await snap("settings.connector.older-gateway") { settingsPage(ConnectorPage(connectorId: "icloud"), older) }
    }

    /// Account's iPhones on Franco's phone: this one and his iPad Air, as the approved page
    /// lists them, the yes that Remove asks for, and the code that pairs a new iPhone.
    func testAccountPhones() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        try await mount { settingsPage(AccountPage(), gateway) }
        await gateway.eventually("phones read") { gateway.model.pairedPhones.phones.count == 2 }
        try await capture("settings.account.phones")
        try await snap("settings.account.phones.dark", dark: true) { settingsPage(AccountPage(), gateway) }

        let ipad = try XCTUnwrap(gateway.model.pairedPhones.phones.first { $0.id == "franco-ipad" })
        try await snap("settings.account.remove-confirm") { settingsPage(AccountPage(removing: ipad), gateway) }

        // Each code is asked for as its page opens, and forgotten as it closes.
        await gateway.model.pairedPhones.askForCode()
        XCTAssertNotNil(gateway.model.pairedPhones.newPhoneCode)
        try await snap("settings.account.pair-code") { settingsPage(AccountPage(isShowingNewPhoneCode: true), gateway) }
        await gateway.model.pairedPhones.askForCode()
        try await snap("settings.account.pair-code.dark", dark: true) {
            settingsPage(AccountPage(isShowingNewPhoneCode: true), gateway)
        }
    }

    /// Real rooms, settings and previews use every preset, including both defaults.
    func testAppearanceReachesTheRooms() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        var listening = TalkSession()
        _ = listening.handle(.began)
        _ = listening.handle(.heard("What's on the family calendar?", at: Date()))
        for dark in [false, true] {
            for theme in AppTheme.allCases {
                let settings = gateway.model.settings
                settings.theme = theme
                let name = "themes." + theme.rawValue + (dark ? ".dark" : ".light")
                try await snap(name + ".chats", dark: dark) {
                    InboxView().environment(gateway.model).phonePreferences(settings).tint(Palette.highlight)
                }
                try await snap(name + ".room", dark: dark) { roomScreen(.direct, gateway).phonePreferences(settings) }
                try await snap(name + ".family", dark: dark) { roomScreen(.family, gateway).phonePreferences(settings) }
                try await snap(name + ".call", dark: dark) { callScreen(listening, gateway).phonePreferences(settings) }
                gateway.model.tab = .settings
                try await snap(name + ".settings", dark: dark) {
                    InboxView().environment(gateway.model).phonePreferences(settings).tint(Palette.highlight)
                }
                gateway.model.tab = .chats
                try await snap(name + ".appearance", dark: dark) {
                    settingsPage(AppearancePage(), gateway).phonePreferences(settings).tint(Palette.highlight)
                }
                try await snap(name + ".preview", dark: dark) {
                    AppearancePreview(scheme: dark ? .dark : .light).environment(gateway.model).phonePreferences(settings)
                }
                if theme != .default, Self.isWanted(name + ".accessible") {
                    try await SimulatorAccessibility.with(.reduceTransparency) {
                        try await snap(name + ".accessible", dark: dark, isContrastIncreased: true) {
                            roomScreen(.direct, gateway).phonePreferences(settings)
                        }
                    }
                }
            }
        }
        gateway.model.settings.revertAppearance()
    }

    /// Corey's thread and its composer as every phone draws them by default, in the light
    /// and the dark that Light, Dark and Auto come to, then with each iPhone setting that
    /// changes the glass, Increase Contrast and Reduce Transparency, light and dark. Then a
    /// voice note held, where the microphone is at its biggest, which a scale had blurred.
    func testTheLookUnderEachAppearanceAndAccessibilitySetting() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        for isDark in [false, true] {
            let scheme = isDark ? ".dark" : ""
            try await snap("look.default" + scheme, dark: isDark) { roomScreen(.direct, gateway) }
            if Self.isWanted("look.increase-contrast" + scheme) {
                try await SimulatorAccessibility.with(.increaseContrast) {
                    try await snap("look.increase-contrast" + scheme, dark: isDark, isContrastIncreased: true) {
                        roomScreen(.direct, gateway)
                    }
                }
            }
            if Self.isWanted("look.reduce-transparency" + scheme) {
                try await SimulatorAccessibility.with(.reduceTransparency) {
                    try await snap("look.reduce-transparency" + scheme, dark: isDark) { roomScreen(.direct, gateway) }
                }
            }
        }
        var holding = VoiceNoteGesture()
        holding.press(at: Date().addingTimeInterval(-3))
        for isDark in [false, true] {
            try await snap("look.hold" + (isDark ? ".dark" : ""), dark: isDark) {
                composer(gateway, voiceNote: holding, levels: Self.heardLevels)
            }
        }
    }

    /// The original Light and Dark bubble rims. Franco's own bubbles stay royal. His
    /// thread ends with the exchange the approved comparison draws.
    func testAssistantRim() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("Are we free Friday night?", by: DemoRoom.person, in: .direct)
        gateway.room.say("You are. Gia has yoga until 6:30, then the evening is open.", by: DemoRoom.assistant, in: .direct)
        gateway.room.say("Book movie night", by: DemoRoom.person, in: .direct)
        gateway.room.say("Done. Movie night is on the family calendar for Friday at 7.", by: DemoRoom.assistant, in: .direct)
        await gateway.changed()
        try await snap("room.direct.rim-standard") { roomScreen(.direct, gateway).phonePreferences(gateway.model.settings) }
        try await snap("room.direct.rim-standard.dark", dark: true) { roomScreen(.direct, gateway).phonePreferences(gateway.model.settings) }
        try await snap("room.family.rim-standard.dark", dark: true) { roomScreen(.family, gateway).phonePreferences(gateway.model.settings) }
        gateway.model.settings.revertAppearance()
    }

    // MARK: - Mentions and the room's header

    /// @mentions in the family room, in everyone's words: gold for an assistant, royal for
    /// a person, white and bright gold on Franco's own bubble, and links in an assistant's.
    func testMentions() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("@Denise what time is Luca's recital on Thursday?", by: "gia")
        gateway.room.say("6 PM at the school, @Gia. It is on the family calendar.", by: "denise")
        gateway.room.say("@Gia I can drive if @Denise sends me the address", by: DemoRoom.person)
        await gateway.changed()
        for isDark in [false, true] {
            try await snap("room.family.mentions" + (isDark ? ".dark" : ""), dark: isDark) { roomScreen(.family, gateway) }
        }

        // Gia names Franco and then Corey, so both are lit on Franco's phone.
        let mine = FixtureGateway()
        await mine.connect()
        mine.room.say("@Franco can you grab basil on the way home?", by: "gia")
        mine.room.say("And @corey, put it on the shopping list please", by: "gia")
        mine.room.say("Basil is on the shopping list, @Gia.", by: DemoRoom.assistant)
        await mine.changed()
        for isDark in [false, true] {
            try await snap("room.family.mention-me" + (isDark ? ".dark" : ""), dark: isDark) { roomScreen(.family, mine) }
        }
    }

    /// Corey's photo at the top of his thread, in the gold ring, over his name.
    func testHeaderPhoto() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        for isDark in [false, true] {
            try await snap("room.direct.header-photo" + (isDark ? ".dark" : ""), dark: isDark) { roomScreen(.direct, gateway) }
        }
    }

    /// Denise's message lifted in the family room, its menu offering to ask Corey about
    /// it. Asking leaves a reply quoting it, with Corey mentioned first in the draft.
    func testAskTheAssistant() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let line = try gateway.message(.family) { $0.author == "denise" }
        let row = CGRect(x: 0, y: 520, width: 402, height: 96)
        for isDark in [false, true] {
            try await snap("room.family.ask-assistant-menu" + (isDark ? ".dark" : ""), dark: isDark) { liftedScreen(line, at: row, gateway) }
        }
        try await snap("room.family.ask-assistant-reply") {
            ZStack(alignment: .bottom) {
                MeshBackground()
                RoomComposer(conversation: .family, replyingTo: .constant(line), asking: .constant(gateway.model.assistantName))
            }
            .environment(gateway.model)
        }
    }

    /// Corey's and Denise's Telegram photos, by participant, as the extensions are given them.
    private static func assistantPhotos() throws -> [String: UIImage] {
        var photos: [String: UIImage] = [:]
        for assistant in ["corey", "denise"] {
            photos[assistant] = try XCTUnwrap(UIImage(data: Fixtures.face(assistant)), "\(assistant)'s face")
        }
        return photos
    }

    /// Scrolls the list on screen down by `distance`, as a finger would.
    private func scrollTheList(by distance: CGFloat) throws {
        let window = try XCTUnwrap(window, "nothing is on screen to scroll")
        let list = try XCTUnwrap(Self.verticalScrollView(in: window), "nothing on screen scrolls up and down")
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: list.contentOffset.y + distance), animated: true)
    }

    /// The list on screen scrolled to its very end, as far as a finger could take it.
    private func scrollToTheEnd() throws {
        let window = try XCTUnwrap(window, "nothing is on screen to scroll")
        let list = try XCTUnwrap(Self.verticalScrollView(in: window), "nothing on screen scrolls up and down")
        let end = max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: end), animated: true)
    }

    /// The first view that scrolls up and down: the list, not the strip of shared things in it.
    private static func verticalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.height {
            return scroll
        }
        for subview in view.subviews {
            if let found = verticalScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Location

    func testLocation() async throws {
        // Franco shares with Corey and the family room until midnight: nothing on Chats, as it
        // runs in the background, the Location row in Settings, and Location itself.
        let sharing = FixtureGateway()
        sharing.model.settings.locationSharing = LocationSharing(audience: .family, span: .tonight, from: Date(), calendar: .current)
        await sharing.connect()
        try await snap("chats.location-sharing", sharing)
        try await snap("chats.location-sharing.dark", sharing, dark: true)
        try await snap("settings.location-row") { SettingsView().environment(sharing.model) }
        try await snap("settings.location.on") { NavigationStack { LocationSettingsView() }.environment(sharing.model) }
        try await snap("settings.location.on.dark", dark: true) { NavigationStack { LocationSettingsView() }.environment(sharing.model) }

        // Paused from Settings, and Corey has forgotten: Chats still says nothing.
        let paused = FixtureGateway()
        var pausedSharing = LocationSharing(audience: .assistant, span: .always, from: Date(), calendar: .current)
        pausedSharing.isPaused = true
        paused.model.settings.locationSharing = pausedSharing
        await paused.connect()
        try await snap("chats.location-paused", paused)

        // Precise Location turned off in the app: only the neighbourhood is sent.
        let approximate = FixtureGateway()
        approximate.model.settings.locationSharing = LocationSharing(audience: .assistant, span: .hour, from: Date(), calendar: .current)
        approximate.model.settings.isLocationPrecise = false
        await approximate.connect()
        try await snap("settings.location.approximate") { NavigationStack { LocationSettingsView() }.environment(approximate.model) }
        try await snap("settings.location.approximate.dark", dark: true) { NavigationStack { LocationSettingsView() }.environment(approximate.model) }

        // Off, as everybody starts.
        let off = FixtureGateway()
        await off.connect()
        try await snap("settings.location.off.xxl", type: .accessibility2) { NavigationStack { LocationSettingsView() }.environment(off.model) }
    }

    /// Account and Location in each state sharing can be in, with iOS's answer as it would
    /// be, so both can be seen to say the same thing. Account once said "On" for iOS's
    /// permission beside a Location whose switch was off.
    func testLocationStates() async throws {
        var paused = LocationSharing(audience: .assistant, span: .always, from: Date(), calendar: .current)
        paused.isPaused = true
        let states: [(id: String, permission: PermissionStatus, sharing: LocationSharing?, isHeld: Bool)] = [
            ("sharing", .allowed, LocationSharing(audience: .assistant, span: .hour, from: Date(), calendar: .current), true),
            ("sharing-family", .allowed, LocationSharing(audience: .family, span: .tonight, from: Date(), calendar: .current), true),
            ("paused", .allowed, paused, false),
            // iOS allows While Using and the app's own switch is off: what the owner saw.
            ("off", .allowed, nil, false),
            // Stopped, and the stop has not reached the gateway yet.
            ("forgetting", .allowed, nil, true),
            ("not-allowed", .denied, nil, false),
        ]
        for state in states {
            let gateway = FixtureGateway()
            gateway.model.permissions.statuses[.location] = state.permission
            gateway.model.settings.locationSharing = state.sharing
            gateway.model.settings.isLocationHeldByGateway = state.isHeld
            // A stop owed to the gateway stays on its way, so the gateway still holds the
            // position while the pages are drawn.
            gateway.answers["household-app.location"] = nil
            await gateway.connect()

            let accountId = "settings.account.location-\(state.id)"
            if Self.isWanted(accountId) {
                try await mount { settingsPage(AccountPage(), gateway) }
                await gateway.eventually("phones read") { gateway.model.pairedPhones.phones.count == 2 }
                // Down to what this iPhone lets Steward AI use, at the end of the page.
                let page = try XCTUnwrap(window.flatMap { Self.verticalScrollView(in: $0) }, "Account does not scroll")
                let end = page.contentSize.height - page.bounds.height + page.adjustedContentInset.bottom
                page.setContentOffset(CGPoint(x: page.contentOffset.x, y: max(end, -page.adjustedContentInset.top)), animated: true)
                try await Task.sleep(for: .milliseconds(700))
                try await capture(accountId)
            }
            try await snap("settings.location.\(state.id)") { NavigationStack { LocationSettingsView() }.environment(gateway.model) }
        }
    }

    // MARK: - Maps

    /// Franco downtown, a few streets north of home, measured a moment ago.
    private static func nearHome(north metres: Double = 1700) -> LocationReport.Position {
        LocationFix(latitude: 39.7684 + metres / 111_195, longitude: -86.1560, accuracy: 12, at: Date().addingTimeInterval(-20)).position
    }

    private static let home = #"{"latitude":39.7684,"longitude":-86.1581}"#

    /// A map, given a moment more than other screens, since MapKit draws its tiles first.
    private func snapMap<Content: View>(_ id: String, dark: Bool = false, @ViewBuilder _ content: () -> Content) async throws {
        guard Self.isWanted(id) else {
            return
        }
        try await mount(dark: dark, content)
        try await Task.sleep(for: .seconds(2))
        try await capture(id)
    }

    /// The assistant's small map, without the way and with it, Franco's live map in the
    /// family room with the share menu it came from, and reminders by place: his own to
    /// set, one set, Denise asking his yes, and Corey's waiting for Gia's and answered.
    /// MapKit draws the tiles on the Mac's simulator; without them each map shows its
    /// quiet panel, with the faces, pins, the way and the circles placed all the same.
    func testMaps() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.room.say("Where is the soccer field?", by: DemoRoom.person, in: .direct)
        let field = #"{"type":"map","center":{"latitude":39.7817,"longitude":-86.1478},"label":"Soccer field"}"#
        gateway.room.say("It is on Maple Street, behind the school.\n\n```steward-card\n\(field)\n```", by: DemoRoom.assistant, in: .direct)
        await gateway.changed()
        try await snapMap("room.direct.card-map") { roomScreen(.direct, gateway) }
        try await snapMap("room.direct.card-map.dark", dark: true) { roomScreen(.direct, gateway) }

        let routed = FixtureGateway()
        await routed.connect()
        // At 5:52 PM, as the mockup asks it.
        let asked = routed.room.minutesAgo(at: 17, 52)
        routed.room.say("How long till I'm home?", by: DemoRoom.person, in: .direct, minutesAgo: asked)
        let homeCard = #"{"type":"map","center":\#(Self.home),"label":"Home","route":"driving"}"#
        let answer = routed.room.say(
            "You are 18 minutes from home. Traffic is light.\n\n```steward-card\n\(homeCard)\n```",
            by: DemoRoom.assistant,
            in: .direct,
            minutesAgo: asked
        )
        await routed.changed()
        let card = MapCard(center: MapPoint(latitude: 39.7684, longitude: -86.1581), label: "Home", route: .driving)
        routed.model.mapRoutes.keep(
            MapRoute(
                points: [(39.7837, -86.1560), (39.7837, -86.1625), (39.7752, -86.1625), (39.7752, -86.1581), (39.7684, -86.1581)]
                    .map { MapPoint(latitude: $0.0, longitude: $0.1) },
                seconds: 18 * 60 + 20,
                metres: 9_800,
                name: "Maple Street"
            ),
            for: card.routeKey(in: answer.id)
        )
        try await snapMap("room.direct.card-map-route") { roomScreen(.direct, routed) }
        try await snapMap("room.direct.card-map-route.dark", dark: true) { roomScreen(.direct, routed) }

        let live = FixtureGateway()
        await live.connect()
        live.room.say("Are you close? Dinner's on the table.", by: "gia")
        let map = live.room.shareMap(by: DemoRoom.person, at: Self.nearHome(north: 2400), until: Date().addingTimeInterval(45 * 60), minutesAgo: 1)
        live.room.moveMap(map.id, by: DemoRoom.person, to: Self.nearHome())
        live.room.say("I can see you \u{1F64C}", by: "gia")
        await live.changed()
        try await snapMap("room.family.share-live") { roomScreen(.family, live) }
        try await snapMap("room.family.share-live.dark", dark: true) { roomScreen(.family, live) }
        try await snap("composer.location-menu") { composer(live, isLocationMenuOpen: true) }
        try await snap("composer.location-menu.dark", dark: true) { composer(live, isLocationMenuOpen: true) }

        let reminder = FixtureGateway()
        await reminder.connect()
        reminder.room.say("Remind me to take the trash out when I get home.", by: DemoRoom.person, in: .direct)
        let trash = #"{"type":"place-reminder","text":"Take the trash out","place":{"label":"home","latitude":39.7684,"longitude":-86.1581},"when":"arrive"}"#
        let trashAnswer = reminder.room.say("I will remind you when you get home. Tap Set and your iPhone watches for it.\n\n```steward-card\n\(trash)\n```", by: DemoRoom.assistant, in: .direct)
        await reminder.changed()
        try await snapMap("room.direct.card-place-reminder") { roomScreen(.direct, reminder) }
        try await snapMap("room.direct.card-place-reminder.dark", dark: true) { roomScreen(.direct, reminder) }
        reminder.model.placeReminders.watch(PlaceWatch(
            id: trashAnswer.id,
            text: "Take the trash out",
            label: "home",
            center: MapPoint(latitude: 39.7684, longitude: -86.1581),
            radius: 150,
            when: .arrive,
            repliesInRoom: false
        ))
        try await snapMap("room.direct.card-place-reminder-set") { roomScreen(.direct, reminder) }

        let consent = FixtureGateway()
        await consent.connect()
        consent.room.say("Denise, tell me when Franco leaves work.", by: "gia")
        let asking = #"{"type":"place-reminder","text":"Tell Gia","place":{"label":"work","latitude":39.7817,"longitude":-86.1478,"radius":200},"when":"leave","for":"Franco"}"#
        consent.room.say("Franco, Gia would like to know when you leave work. Only your iPhone can watch for it.\n\n```steward-card\n\(asking)\n```", by: "denise")
        await consent.changed()
        try await snapMap("room.family.place-consent") { roomScreen(.family, consent) }
        try await snapMap("room.family.place-consent.dark", dark: true) { roomScreen(.family, consent) }

        let waiting = FixtureGateway()
        await waiting.connect()
        waiting.room.say("Corey, tell me when Gia leaves work.", by: DemoRoom.person)
        let corey = #"{"type":"place-reminder","text":"Tell Franco","place":{"label":"work","latitude":39.7817,"longitude":-86.1478,"radius":200},"when":"leave","for":"Gia"}"#
        let request = waiting.room.say("I asked Gia's iPhone. It will tell you when she leaves, once she says yes.\n\n```steward-card\n\(corey)\n```", by: DemoRoom.assistant)
        await waiting.changed()
        try await snapMap("room.family.place-consent-waiting") { roomScreen(.family, waiting) }
        waiting.room.answerPlace(request.id, by: "gia", with: "yes")
        await waiting.changed()
        try await snapMap("room.family.place-consent-answered") { roomScreen(.family, waiting) }
        try await snapMap("room.family.place-consent-answered.dark", dark: true) { roomScreen(.family, waiting) }
    }

    // MARK: - Onboarding

    func testOnboarding() async throws {
        let fresh = FixtureGateway(host: "")
        fresh.model.connect()
        try await snap("onboarding.unpaired", fresh)
        let steps: [(id: String, step: OnboardingView.Step, member: HouseholdMember?)] = [
            ("onboarding.welcome", .welcome, nil),
            ("onboarding.facts", .facts, nil),
            ("onboarding.who", .who, nil),
            ("onboarding.code", .code, .franco),
            ("onboarding.code.gia", .code, .gia),
        ]
        for shot in steps {
            try await snap(shot.id) {
                OnboardingView(step: shot.step, member: shot.member).environment(fresh.model)
            }
        }
        try await snap("onboarding.welcome.dark", dark: true) {
            OnboardingView().environment(fresh.model)
        }
        try await snap("onboarding.who.dark", dark: true) {
            OnboardingView(step: .who, member: nil).environment(fresh.model)
        }
        // The light partway across Get started, held there for the picture.
        try await snap("onboarding.welcome.glide") {
            OnboardingView(heldGlide: 0.55).environment(fresh.model)
        }
        try await snap("onboarding.code.xxl", type: .accessibility2) {
            OnboardingView(step: .code, member: .franco).environment(fresh.model)
        }
        let waiting = FixtureGateway(host: "", appleSignInWait: AppleSignInWait(member: "gia", requestId: "gia-req-1", ticket: "ticket"))
        try await snap("onboarding.waiting-for-franco") {
            OnboardingView(step: .code, member: .gia).environment(waiting.model)
        }
        try await snap("onboarding.code.not-a-code") {
            OnboardingView(
                step: .code,
                member: .franco,
                refusal: "That is not a Steward AI code. Copy the code from Telegram and try again."
            )
            .environment(fresh.model)
        }

        // A code that pairs: the setup connect, then the operator's, then what is worth
        // turning on, then the chats.
        let pairing = FixtureGateway(host: "", paired: false)
        pairing.model.settings.hasOfferedPermissions = false
        pairing.offersChallenge = false
        pairing.model.pair(try setupCode())
        try await snap("onboarding.pairing") {
            OnboardingView(step: .pairing, member: .franco).environment(pairing.model)
        }
        pairing.offersChallenge = true
        pairing.model.connect()
        await pairing.eventually("paired") { pairing.model.isPaired && pairing.model.room.isAvailable == true }
        try await snap("onboarding.permissions", pairing)
        pairing.model.settings.hasOfferedPermissions = true
        try await snap("onboarding.done", pairing)

        for (index, kind) in PermissionKind.allCases.enumerated() {
            try await snap("permissions.\(kind.rawValue)") {
                PermissionStepsView(steps: PermissionKind.allCases, index: index).environment(pairing.model)
            }
        }
        try await snap("permissions.notifications.dark", dark: true) {
            PermissionStepsView(steps: PermissionKind.allCases, index: 0).environment(pairing.model)
        }
        try await snap("permissions.voice.dark", dark: true) {
            PermissionStepsView(steps: PermissionKind.allCases, index: 1).environment(pairing.model)
        }
        try await snap("permissions.location.xxl", type: .accessibility2) {
            PermissionStepsView(steps: PermissionKind.allCases, index: 2).environment(pairing.model)
        }
        try await snap("permissions.location.dark", dark: true) {
            PermissionStepsView(steps: PermissionKind.allCases, index: 2).environment(pairing.model)
        }

        // Once the microphone is allowed its bars move with the room, held here mid-word.
        let heard = [0.06, 0.08, 0.14, 0.32, 0.58, 0.81, 0.64, 0.42, 0.7, 0.92, 0.68, 0.36, 0.22, 0.48, 0.74, 0.6,
                     0.33, 0.16, 0.1, 0.26, 0.52, 0.71, 0.45, 0.24, 0.12, 0.3, 0.57, 0.38]
        try await snap("onboarding.microphone.live") {
            PermissionStepsView(steps: PermissionKind.allCases, index: 1, heldLevels: heard).environment(pairing.model)
        }
        try await snap("onboarding.microphone.live.dark", dark: true) {
            PermissionStepsView(steps: PermissionKind.allCases, index: 1, heldLevels: heard).environment(pairing.model)
        }
        // Location with Precise Location as its own switch, on as iOS's own starts.
        for (id, isDark) in [("onboarding.location.precise", false), ("onboarding.location.precise.dark", true)] {
            try await snap(id, dark: isDark) {
                PermissionStepsView(steps: [.location], index: 0).environment(pairing.model)
            }
        }
        try await snap("settings.permissions") { settingsPage(AccountPage(), pairing) }

        let spent = FixtureGateway(host: "", paired: false)
        spent.refuse(
            "connect",
            code: "INVALID_REQUEST",
            message: "unauthorized: setup code invalid, expired, revoked, or already used",
            detailCode: "AUTH_BOOTSTRAP_TOKEN_INVALID"
        )
        spent.model.pair(try setupCode())
        await spent.eventually("refused") {
            if case .needsPairing = spent.model.connection.state { return true }
            return false
        }
        try await snap("onboarding.code-rejected") {
            OnboardingView(step: .pairing, member: .franco).environment(spent.model)
        }

        let moving = FixtureGateway()
        await moving.connect()
        let link = try XCTUnwrap(URL(string: "steward://pair?code=\(try setupCodeText())"))
        moving.model.open(link)
        XCTAssertNotNil(moving.model.pendingPairingCode, "a paired phone asks before it moves")
        try await snap("onboarding.move-confirm", moving)
    }

    /// A setup code like the one Corey sends, valid for the next ten minutes.
    private func setupCodeText() throws -> String {
        let fields: [String: Any] = [
            "url": "wss://\(FixtureGateway.host)",
            "bootstrapToken": "single-use",
            "expiresAtMs": (Date().timeIntervalSince1970 + 600) * 1000,
            "access": "limited",
            "person": "franco",
            "assistant": "Corey",
        ]
        return Base64URL.encode(try JSONSerialization.data(withJSONObject: fields))
    }

    private func setupCode() throws -> PairingCode {
        try XCTUnwrap(PairingCode(text: try setupCodeText()))
    }

    // MARK: - Widgets

    /// Every widget size for both conversations, drawn from the snapshot the app keeps in
    /// the App Group for the demo household, with Corey's and Denise's photos. The family
    /// room is where its mockup draws it, Denise's line at 6:14 PM and three new for
    /// Franco, before he answers her. They are drawn in full colour, the way the Home
    /// Screen draws them; the tinted and clear Home Screens and the Lock Screen's tint are
    /// the system's, and only a phone shows them.
    func testWidgets() async throws {
        let gateway = FixtureGateway(isSceneFinished: false)
        await gateway.connect()
        let pickup = "Leave for soccer pickup in 15 minutes \u{26BD}\u{FE0F}"
        gateway.room.say(pickup, by: DemoRoom.assistant, in: .direct)
        gateway.room.say("Gia's flight lands at 4:10 \u{2708}\u{FE0F}", by: "denise", minutesAgo: gateway.room.minutesAgo(at: 18, 14))
        await gateway.changed()

        // The app writes what the widgets show as the room changes.
        await gateway.eventually("the snapshot follows the room") {
            WidgetSnapshot.load().direct.lines.last?.text == pickup
        }
        let snapshot = WidgetSnapshot.load()
        XCTAssertEqual(snapshot.assistantName, "Corey")
        XCTAssertEqual(snapshot.faces.map(\.id), ["franco", "corey", "denise", "gia"])
        XCTAssertEqual(snapshot.family.lines.last?.author, "denise")
        XCTAssertEqual(snapshot.direct.unread, 3, "Franco had read Corey's thread up to Monday's answer")

        let photos = try Self.assistantPhotos()
        for conversation in RoomConversation.allCases {
            let name = conversation == .family ? "family" : "assistant"
            try await snap("widget.home.\(name)") { homeScreen(conversation, snapshot, photos: photos) }
            try await snap("widget.home.\(name).dark", dark: true) { homeScreen(conversation, snapshot, photos: photos) }
            try await snap("widget.lock.\(name)", dark: true) { lockScreen(conversation, snapshot, photos: photos) }
            // As iOS draws the Lock Screen, vibrant: before, the circle drew its photo or
            // emoji there whatever the mode, which is what full colour draws now.
            try await snap("widget.lock.\(name).vibrant.before", dark: true) {
                lockScreen(conversation, snapshot, photos: photos, renderingMode: .fullColor)
            }
            try await snap("widget.lock.\(name).vibrant", dark: true) {
                lockScreen(conversation, snapshot, photos: photos, renderingMode: .vibrant)
            }
        }
        try await snap("widget.home.family.xxl", type: .accessibility2) { homeScreen(.family, snapshot, photos: photos) }

        // Paired, before anybody has said anything, and before the phone is paired at all.
        var quiet = WidgetSnapshot()
        quiet.assistantName = "Corey"
        quiet.assistantEmoji = "\u{1F989}"
        quiet.faces = snapshot.faces
        try await snap("widget.home.family.quiet") { homeScreen(.family, quiet, photos: [:]) }
        try await snap("widget.home.assistant.unpaired") { homeScreen(.direct, WidgetSnapshot(), photos: [:]) }
        try await snap("widget.lock.assistant.unpaired", dark: true) { lockScreen(.direct, WidgetSnapshot(), photos: [:]) }
    }

    /// The Home Screen's sizes on a 402-point-wide iPhone.
    private static let homeSizes: [(family: WidgetFamily, size: CGSize)] = [
        (.systemSmall, CGSize(width: 170, height: 170)),
        (.systemMedium, CGSize(width: 364, height: 170)),
        (.systemLarge, CGSize(width: 364, height: 382)),
    ]

    /// One conversation's widget in each size on a bright wallpaper. WidgetKit draws the
    /// container background, the margins and the rounded corners; off the Home Screen
    /// this draws them itself.
    private func homeScreen(_ conversation: RoomConversation, _ snapshot: WidgetSnapshot, photos: [String: UIImage]) -> some View {
        ZStack {
            LinearGradient(
                colors: [Palette.sheenSky, Palette.sheenViolet.mix(with: Palette.sheenRose, by: 0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.homeSizes.indices, id: \.self) { index in
                    ConversationWidgetView(family: Self.homeSizes[index].family, conversation: conversation, snapshot: snapshot, photos: photos)
                        .padding(16)
                        .frame(width: Self.homeSizes[index].size.width, height: Self.homeSizes[index].size.height)
                        .background(WidgetBackground())
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Palette.shadow, radius: 12, y: 6)
                }
            }
        }
    }

    /// One conversation's Lock Screen widgets laid out as the mockup lays them out: the
    /// line by the date, the clock, then the circle, the rectangle and the Talk button.
    /// Given a rendering mode, they are drawn as iOS draws the Lock Screen vibrant: from
    /// each pixel's brightness alone, in white over the wallpaper.
    private func lockScreen(
        _ conversation: RoomConversation,
        _ snapshot: WidgetSnapshot,
        photos: [String: UIImage],
        renderingMode: WidgetRenderingMode? = nil
    ) -> some View {
        let widgets = lockWidgets(conversation, snapshot, photos: photos, renderingMode: renderingMode)
        return ZStack {
            LinearGradient(colors: [Palette.navyDeep, Palette.royalDeep], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if renderingMode == nil {
                widgets
            } else {
                Color.white
                    .mask {
                        widgets.luminanceToAlpha()
                    }
            }
        }
    }

    private func lockWidgets(
        _ conversation: RoomConversation,
        _ snapshot: WidgetSnapshot,
        photos: [String: UIImage],
        renderingMode: WidgetRenderingMode?
    ) -> some View {
        func accessory(_ family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
            ConversationWidgetView(family: family, conversation: conversation, snapshot: snapshot, photos: photos, accessoryRenderingMode: renderingMode)
                .frame(width: width, height: height)
        }
        return VStack(spacing: 4) {
            accessory(.accessoryInline, width: 300, height: 22)
            Text("9:41")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
            HStack(spacing: 12) {
                accessory(.accessoryCircular, width: 72, height: 72)
                accessory(.accessoryRectangular, width: 172, height: 76)
                TalkWidgetView(assistantName: snapshot.assistantName)
                    .frame(width: 72, height: 72)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 70)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Sharing

    /// The Share Extension's sheet, drawn from the snapshot the app keeps in the App Group:
    /// opened from the Share Sheet's top row on Corey with two pictures and a link, on the
    /// family room with a file, still reading, refused, on a phone not paired yet, and on
    /// its way.
    func testShareSheet() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        await gateway.eventually("the snapshot knows who this phone is") { WidgetSnapshot.load().me != nil }
        let snapshot = WidgetSnapshot.load()
        let photos = try Self.assistantPhotos()
        let pictures = [
            ShareSheetItem(kind: .photo, title: "IMG_2041.HEIC", thumbnail: UIImage(data: DemoMedia.scene(.beach, width: 600, height: 450))),
            ShareSheetItem(kind: .video, title: "IMG_2042.MOV", thumbnail: UIImage(data: DemoMedia.scene(.sunset, width: 450, height: 600))),
            ShareSheetItem(kind: .link, title: "example.com/weeknight-pesto-pasta"),
        ]
        let slip = [ShareSheetItem(kind: .file, title: "Field trip permission slip.pdf")]

        try await snap("share.compose") { shareSheet(snapshot, photos, pictures, .direct, words: "Can we make this Sunday?") }
        try await snap("share.compose.dark", dark: true) { shareSheet(snapshot, photos, pictures, .direct, words: "Can we make this Sunday?") }
        try await snap("share.compose.xxl", type: .accessibility2) { shareSheet(snapshot, photos, pictures, .direct) }
        try await snap("share.compose.family") { shareSheet(snapshot, photos, slip, .family, words: "Signed, can someone drop it at school?") }
        try await snap("share.compose.loading") { shareSheet(snapshot, photos, Array(pictures.prefix(1)), .direct, isLoading: true) }
        try await snap("share.compose.left-out") {
            shareSheet(snapshot, photos, Array(pictures.prefix(2)), .family, notice: "Something shared is too large to send, so it was left out.")
        }
        try await snap("share.compose.refused") {
            shareSheet(snapshot, photos, [], .family, notice: "Up to ten things go in one message", isRefused: true)
        }
        try await snap("share.compose.unpaired") { shareSheet(WidgetSnapshot(), [:], pictures, .direct) }
        try await snap("share.compose.sent") { shareSheet(snapshot, photos, pictures, .family, isSent: true) }
        try await snap("share.compose.sent.dark", dark: true) { shareSheet(snapshot, photos, pictures, .direct, isSent: true) }
    }

    /// What was shared from another app, in the room: waiting while the link is down, on
    /// its way once the room sends it, and gone from the App Group once the gateway keeps
    /// it under its hand-off's id.
    func testSharedIntoTheRoom() async throws {
        let beach = DemoMedia.scene(.beach, width: 1200, height: 900)

        let waiting = FixtureGateway()
        await waiting.connect()
        await waiting.dropLink()
        _ = try handOff("From the beach this morning", photo: beach, to: .family, in: waiting.outbox)
        waiting.model.collectShares()
        await waiting.eventually("on its way") { !waiting.model.shares.waiting(in: .family).isEmpty }
        try await snap("room.family.share-waiting") { roomScreen(.family, waiting) }
        try await snap("room.family.share-waiting.dark", dark: true) { roomScreen(.family, waiting) }

        // The upload is never answered here, so the message stays on its way.
        let sending = FixtureGateway()
        await sending.connect()
        _ = try handOff("From the beach this morning", photo: beach, to: .family, in: sending.outbox)
        try await mount { roomScreen(.family, sending) }
        sending.model.collectShares()
        await sending.eventually("sending") { sending.model.room.family.messages.last?.status == .sending }
        try await capture("room.family.share-sending")

        let sent = FixtureGateway()
        await sent.connect()
        let id = try handOff("Can we make this Sunday? https://example.com/weeknight-pesto-pasta", photo: nil, to: .direct, in: sent.outbox)
        sent.model.collectShares()
        await sent.eventually("kept") { sent.model.room.direct.messages.contains { $0.id == "d-" + id && $0.rev != nil } }
        XCTAssertEqual(sent.outbox.pending(), [], "gone from the App Group once the gateway has it")
        XCTAssertEqual(sent.room.entries.filter { $0.id == "d-" + id }.count, 1)
    }

    /// The message menu's Share, for a voice note and for a file with words, and the
    /// conversation menu, which shares or copies the whole chat.
    func testShareMenus() async throws {
        let gateway = FixtureGateway()
        await gateway.connect()
        let voice = try gateway.message(.family) { $0.media.first?.kind == .voice }
        try await snap("room.family.message-share.voice") {
            liftedScreen(voice, at: CGRect(x: 0, y: 470, width: 402, height: 70), gateway)
        }
        let slip = try gateway.message(.direct) { $0.media.first?.kind == .file }
        try await snap("room.direct.message-share.file") {
            liftedScreen(slip, in: .direct, at: CGRect(x: 0, y: 440, width: 402, height: 150), gateway)
        }
        try await snap("room.direct.message-share.file.dark", dark: true) {
            liftedScreen(slip, in: .direct, at: CGRect(x: 0, y: 440, width: 402, height: 150), gateway)
        }

        try await snap("room.family.conversation-menu") { menuScreen(.family, gateway) }
        try await snap("room.family.conversation-menu.dark", dark: true) { menuScreen(.family, gateway) }
        try await snap("room.direct.conversation-menu") { menuScreen(.direct, gateway) }
    }

    /// The Share Extension's sheet in one state.
    private func shareSheet(
        _ snapshot: WidgetSnapshot,
        _ photos: [String: UIImage],
        _ items: [ShareSheetItem],
        _ conversation: RoomConversation,
        words: String = "",
        notice: String? = nil,
        isRefused: Bool = false,
        isLoading: Bool = false,
        isSent: Bool = false
    ) -> some View {
        ShareComposeView(
            snapshot: snapshot,
            photos: photos,
            previews: items,
            conversation: conversation,
            words: words,
            notice: notice,
            isRefused: isRefused,
            isLoading: isLoading,
            isSent: isSent,
            onCancel: {},
            onSend: { _, _ in }
        )
    }

    /// Leaves a hand-off in `outbox` the way the Share Extension does, and hands back its id.
    private func handOff(_ text: String, photo: Data?, to conversation: RoomConversation, in outbox: ShareOutbox) throws -> String {
        let id = UUID().uuidString.lowercased()
        let draft = try outbox.draft(id)
        var items: [ShareHandoff.Item] = []
        if let photo {
            try photo.write(to: draft.appendingPathComponent("IMG_2041.jpeg"))
            items.append(ShareHandoff.Item(kind: .photo, file: "IMG_2041.jpeg"))
        }
        try outbox.post(ShareHandoff(id: id, conversation: conversation, text: text, items: items, at: Date()))
        return id
    }

    /// A conversation with its menu open.
    private func menuScreen(_ conversation: RoomConversation, _ gateway: FixtureGateway) -> some View {
        NavigationStack {
            RoomView(conversation: conversation)
        }
        .environment(gateway.model)
    }

    // MARK: - Notifications

    /// The faces the app draws for the notification extension, cut to circles the way iOS
    /// shows them on the Lock Screen: a person's initial, and Corey's and Denise's photos,
    /// beside the lines the mockup's Lock Screen shows. The notifications themselves are
    /// the system's, and only a phone shows them.
    func testNotificationFaces() async throws {
        let photos = try Self.assistantPhotos()
        let people: [(participant: RoomParticipant, photo: UIImage?, line: String)] = [
            (RoomParticipant(id: "corey", name: "Corey", kind: .assistant, isOwner: false, emoji: "\u{1F989}"), photos["corey"], "Leave for soccer pickup in 15 minutes"),
            (RoomParticipant(id: "gia", name: "Gia", kind: .person, isOwner: false), nil, "Dinner is ready \u{1F35D}"),
            (RoomParticipant(id: "denise", name: "Denise", kind: .assistant, isOwner: false, emoji: "\u{1F338}"), photos["denise"], DemoRoom.flightWords),
            (RoomParticipant(id: "franco", name: "Franco", kind: .person, isOwner: true), nil, "This phone's own person"),
        ]
        let faces = try people.map { try XCTUnwrap(NotificationFaces.face(of: $0.participant, photo: $0.photo), $0.participant.name) }
        for isDark in [false, true] {
            try await snap("notifications.faces" + (isDark ? ".dark" : ""), dark: isDark) {
                ZStack {
                    MeshBackground()
                    VStack(spacing: 10) {
                        ForEach(people.indices, id: \.self) { index in
                            HStack(spacing: 12) {
                                Image(uiImage: faces[index])
                                    .resizable()
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(people[index].participant.name)
                                        .font(.headline)
                                    Text(people[index].line)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Drawing

    /// A conversation as it shows when opened from Chats.
    private func roomScreen(_ conversation: RoomConversation, _ gateway: FixtureGateway) -> some View {
        NavigationStack {
            RoomView(conversation: conversation)
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

    /// A call in one state, connected four minutes and seven seconds ago and on the speaker,
    /// as a call starts, unless said.
    private func callScreen(
        _ session: TalkSession,
        state: CallState = ScreenshotTests.connectedCall(secondsIn: 247),
        routing: CallRouting = CallRouting(),
        level: Double = 0,
        _ gateway: FixtureGateway
    ) -> some View {
        CallScreen(
            session: session,
            state: state,
            routing: routing,
            level: level,
            onFaceTap: {},
            onMute: {},
            onSpeaker: {},
            onLeave: {},
            onEnd: {}
        )
        .environment(gateway.model)
    }

    /// A call iOS and the gateway connected `secondsIn` seconds ago.
    private static func connectedCall(secondsIn: TimeInterval) -> CallState {
        let connected = Date().addingTimeInterval(-secondsIn)
        var state = CallState()
        state.handle(.audio(isActive: true), at: connected)
        state.handle(.link(isUp: true), at: connected)
        return state
    }

    /// A conversation with `message` lifted for reactions from where its row sat.
    private func liftedScreen(
        _ message: RoomMessage,
        in conversation: RoomConversation = .family,
        at row: CGRect,
        _ gateway: FixtureGateway
    ) -> some View {
        NavigationStack {
            RoomView(conversation: conversation, reacting: message, reactingFrame: row)
        }
        .environment(gateway.model)
    }

    /// The iPhone keyboard's height in portrait, its suggestions and the home indicator's
    /// strip included.
    private static let keyboardHeight: CGFloat = 336

    /// Raises a stand-in for the keyboard over what is on screen, since a hosted test cannot
    /// raise the keyboard itself: the bottom safe area grows to the keyboard's height, as
    /// the keyboard's does, and a plain panel in a keyboard's grey covers that strip.
    private func raiseKeyboardStandIn() throws {
        let window = try XCTUnwrap(window, "nothing is on screen to raise a keyboard over")
        let host = try XCTUnwrap(window.rootViewController, "the window shows no view controller")
        let panel = UIView(frame: CGRect(
            x: 0,
            y: window.bounds.height - Self.keyboardHeight,
            width: window.bounds.width,
            height: Self.keyboardHeight
        ))
        panel.backgroundColor = .systemGray5
        window.addSubview(panel)
        host.additionalSafeAreaInsets.bottom = Self.keyboardHeight - window.safeAreaInsets.bottom
    }

    /// The whole app as it stands, captured.
    private func snap(
        _ id: String,
        _ gateway: FixtureGateway,
        dark: Bool = false,
        type: DynamicTypeSize = .large
    ) async throws {
        try await snap(id, dark: dark, type: type) { RootView().environment(gateway.model) }
    }

    private func snap<Content: View>(
        _ id: String,
        dark: Bool = false,
        type: DynamicTypeSize = .large,
        isContrastIncreased: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) async throws {
        guard Self.isWanted(id) else {
            return
        }
        try await mount(dark: dark, type: type, isContrastIncreased: isContrastIncreased, content)
        if id.hasPrefix("themes."), id.hasSuffix(".room") || id.hasSuffix(".family") || id.hasSuffix(".accessible") {
            try await waitForThemeThread(id)
        }
        try await capture(id)
    }

    /// A theme review needs the settled messages, not the intentionally quiet first-open
    /// screen. Fail if preparation never reveals them instead of accepting a blank shot.
    private func waitForThemeThread(_ id: String) async throws {
        let window = try XCTUnwrap(window)
        func thread(in view: UIView) -> ThreadCollectionView? {
            if let list = view as? ThreadCollectionView { return list }
            for child in view.subviews {
                if let list = thread(in: child) { return list }
            }
            return nil
        }
        for _ in 0..<60 {
            if let list = thread(in: window), list.alpha > 0.99,
               !list.accessibilityElementsHidden, !list.visibleCells.isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("\(id): chat messages did not finish their initial presentation")
    }

    /// A page longer than the screen, shot at its top as `id` and scrolled to its end as
    /// `id.end`.
    private func snapTopAndEnd<Content: View>(
        _ id: String,
        dark: Bool = false,
        type: DynamicTypeSize = .large,
        @ViewBuilder _ content: () -> Content
    ) async throws {
        guard Self.isWanted(id) else {
            return
        }
        try await mount(dark: dark, type: type, content)
        try await capture(id)
        try scrollToTheEnd()
        try await Task.sleep(for: .milliseconds(700))
        try await capture(id + ".end")
    }

    /// The states this run renders: STEWARD_SCREENSHOTS lists id prefixes, separated by
    /// commas, so a preview renders only what a change touches. Unset or empty renders all.
    private static let wantedPrefixes: [String] = (ProcessInfo.processInfo.environment["STEWARD_SCREENSHOTS"] ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    private static func isWanted(_ id: String) -> Bool {
        wantedPrefixes.isEmpty || wantedPrefixes.contains { id.hasPrefix($0) }
    }

    /// Puts the view on screen in a window of its own, the size of the
    /// simulator, and gives SwiftUI a moment to lay it out. `isContrastIncreased` draws it
    /// as Increase Contrast does, for the colours the app gives that setting.
    private func mount<Content: View>(
        dark: Bool = false,
        type: DynamicTypeSize = .large,
        isContrastIncreased: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene,
            "the test host has no window scene"
        )
        window?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: content().environment(\.dynamicTypeSize, type))
        if isContrastIncreased {
            host.traitOverrides.accessibilityContrast = .high
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        try await Task.sleep(for: .milliseconds(700))
    }

    /// Draws what is on screen right now at twice the point size, one scale for every
    /// state, and keeps it as a PNG. The result bundle keeps it too only when the test
    /// fails, where it shows what went wrong; kept always, every picture was in the run
    /// twice.
    private func capture(_ id: String) async throws {
        guard Self.isWanted(id) else {
            return
        }
        let window = try XCTUnwrap(window, "nothing is on screen for \(id)")
        try await Task.sleep(for: .milliseconds(300))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        // Eight bits a channel in sRGB: the wide range drew each picture at sixteen, about
        // ten times the size, with nothing to see for it in a review.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData(), "\(id) did not encode")
        try data.write(to: Self.directory.appendingPathComponent(id + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = id
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
#endif
