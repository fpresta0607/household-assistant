#if canImport(UIKit)
// A gateway made of the captured frames and the demo household, wired into a whole
// `AppModel`, so a screen can be put into any state the real gateway can put it into.
//
// Each method the app calls is answered by one closure: the connect methods from the
// captured fixtures, the household-app methods from `DemoRoom` with Corey's and
// Denise's Telegram photos as their faces, as the mockups show them, its settings from
// `DemoSettings` and Account's iPhones from `DemoPhones`, in the shape the plugin's
// contract gives them. Replace an answer to change a state, or remove it to leave that
// request hanging, which is how every "loading" state is reached.

import Foundation
import XCTest
@testable import HouseholdAssistant

@MainActor
final class FixtureGateway {
    typealias Answer = (GatewayRequest) throws -> String

    let transport = ScriptedTransport()
    let credentials: MemoryCredentialStore
    let model: AppModel
    let room: DemoRoom
    let settings: DemoSettings
    let phones = DemoPhones()
    /// Where this gateway's app finds what the Share Extension left: a folder of its own,
    /// so no test reads another's hand-offs.
    let outbox = ShareOutbox(folder: FileManager.default.temporaryDirectory
        .appendingPathComponent("screenshot-outbox-\(UUID().uuidString)", isDirectory: true))

    var answers: [String: Answer] = [:]
    /// Whether an opened socket is greeted with the challenge. Without it the
    /// handshake never starts, which is what "connecting" looks like.
    var offersChallenge = true

    static let host = "gateway.tail1234.ts.net:18789"
    static let roomMethods = [
        "household-app.history",
        "household-app.sync",
        "household-app.media",
        "household-app.send",
        "household-app.react",
        "household-app.read",
        "household-app.typing",
        "household-app.push.register",
        "household-app.card.tick",
        "household-app.location",
        "household-app.location.live",
        "household-app.place.answer",
        "household-app.approval.answer",
        "household-app.cart.ordered",
        "household-app.look.set",
    ]

    /// Everything an `AppModel` reads from outside itself when it starts: the
    /// settings in the app's defaults, and the widget snapshot in the App
    /// Group. Each gateway a test builds starts from none of it, whatever an
    /// earlier one in the same test wrote.
    static let persistedKeys = [
        "gateway-host", "permissions-offered", "linked-apple-id", "location-sharing", "location-held", "location-precise",
        "live-shares", "place-watches", "place-watches-fired", "today-seen-at", "today-seen-verse-day",
        "appearance", "appearance-custom", "accent", "rainbow", "rim-palette", "glass-tint", "chat-background", "chat-photo",
        "accent-color", "bubble-color", "other-bubble-color", "assistant-rings",
        "reduce-motion", "text-size", "bold-text", "haptics", "transcripts", "read-aloud",
        "app-lock", "app-lock-timing", "contacts-connector",
        VoiceNotePlayer.speedKey,
    ]

    /// The routes a phone signs in with Apple through, answered here so no screenshot
    /// reaches a gateway: a nonce, and a sign-in still waiting for Franco.
    static let applePost: AppleSignInGateway.Post = { url, _ in
        if url.lastPathComponent == "nonce" {
            return (200, Data(#"{"nonce":"fixture-nonce","expiresAtMs":4102444800000}"#.utf8))
        }
        return (200, Data(#"{"waiting":true}"#.utf8))
    }

    static func forgetPersistedState() {
        for key in persistedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        WidgetSnapshot().save()
    }

    /// `appleSignInWait` is a sign-in with Apple this phone was already waiting on.
    /// `isSceneFinished` false leaves the family room just before its scene ends.
    /// `longThread` puts that many older messages in this phone's own thread, as a thread
    /// used for weeks holds.
    init(
        host: String = FixtureGateway.host,
        paired: Bool = true,
        appleSignInWait: AppleSignInWait? = nil,
        isSceneFinished: Bool = true,
        longThread: Int = 0
    ) {
        let room = DemoRoom(isFinished: isSceneFinished, longThread: longThread)
        // Corey and Denise wear their Telegram photos, as both gateways start them.
        for assistant in ["corey", "denise"] {
            guard let photo = try? Fixtures.face(assistant) else {
                XCTFail("the fixtures have no face for \(assistant)")
                continue
            }
            room.faces[assistant] = room.keep(photo, kind: .photo, mime: "image/jpeg", width: 640, height: 640)
        }
        self.room = room
        settings = DemoSettings(room: room)
        credentials = MemoryCredentialStore(
            deviceToken: paired ? StoredDeviceToken(token: "t") : nil
        )
        credentials.appleSignInWait = appleSignInWait
        Self.forgetPersistedState()
        model = AppModel(
            transport: transport,
            credentials: credentials,
            signer: DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "signature" },
            applePost: Self.applePost,
            mediaDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("screenshot-media-\(UUID().uuidString)", isDirectory: true),
            shareOutbox: outbox,
            shouldAskForPermissions: false,
            // "Connecting" and "reconnecting" are drawn as they look once the banner says
            // so, not in the seconds a link is given to come back unseen.
            connectionNoticeDelay: 0
        )
        model.settings.gatewayHost = host
        VoiceNoteTranscripts.shared.remember(DemoRoom.voiceNoteWords, for: room.voiceNote.id)
        // Past the permission steps, so a paired gateway opens on the tabs; the
        // onboarding tests turn this back off to show them.
        model.settings.hasOfferedPermissions = true

        // A setup code's connect earns the node and operator tokens; every other is the operator's.
        answers["connect"] = { request in
            let isSettingUp = request.params["auth"]?["bootstrapToken"] != nil
            return try Fixtures.text(isSettingUp ? "hello-ok-bootstrap" : "hello-ok-device-token", answering: request.id)
        }
        // The captured identity is Denise's, and the demo room is Franco's phone with Corey.
        answers["agent.identity.get"] = { request in
            try Fixtures.text("agent-identity-response", answering: request.id) { frame in
                frame["payload"] = ["agentId": "main", "name": "Corey", "emoji": "\u{1F989}"]
            }
        }
        // Nobody waits for Franco unless a test says so.
        answers["household-app.apple.waiting"] = { try Self.ok($0, .object(["waiting": .array([])])) }
        // Corey has written no Today card unless a test writes one.
        answers["household-app.today"] = { try Self.ok($0, .object(["today": .null])) }
        answers["household-app.apple.nonce"] = {
            try Self.ok($0, .object(["nonce": .string("fixture-nonce"), "expiresAtMs": .number(4_102_444_800_000)]))
        }
        for method in Self.roomMethods {
            answers[method] = { [room] request in
                try Self.ok(request, XCTUnwrap(room.answer(request), "the demo room does not answer \(request.method)"))
            }
        }
        for method in DemoSettings.methods {
            answers[method] = { [settings] request in
                try Self.ok(request, XCTUnwrap(settings.answer(request), "the demo settings do not answer \(request.method)"))
            }
        }
        for method in DemoPhones.methods {
            answers[method] = { [phones] request in
                try Self.ok(request, XCTUnwrap(phones.answer(request), "the demo phones do not answer \(request.method)"))
            }
        }

        transport.onOpen = { [weak self] transport in
            if self?.offersChallenge == true {
                transport.push((try? Fixtures.text("connect-challenge")) ?? "")
            }
        }
        transport.onRequest = { [weak self] transport, request in
            guard let answer = self?.answers[request.method], let text = try? answer(request) else {
                return
            }
            transport.push(text)
        }
    }

    static func ok(_ request: GatewayRequest, _ payload: JSONValue) throws -> String {
        let frame: JSONValue = .object(["type": .string("res"), "id": .string(request.id), "ok": .bool(true), "payload": payload])
        return String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
    }

    /// Answers a method with a refusal, the way the gateway phrases one.
    func refuse(_ method: String, code: String, message: String, detailCode: String) {
        answers[method] = { request in
            #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"\#(code)","message":"\#(message)","details":{"code":"\#(detailCode)"}}}"#
        }
    }

    /// Brings the link up and waits until `settled` holds, by default until the
    /// connect refresh has read who the assistant is and both conversations.
    func connect(
        until settled: @escaping (AppModel) -> Bool = { $0.identity != nil && $0.room.isAvailable == true },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        model.connect()
        await eventually("connected and settled", { self.model.connection.state == .connected && settled(self.model) }, file: file, line: line)
    }

    /// The far end hangs up and never answers again, so the phone stays on
    /// "reconnecting" rather than coming straight back.
    func dropLink() async {
        offersChallenge = false
        transport.drop()
        await eventually("reconnecting") {
            if case .reconnecting = self.model.connection.state { return true }
            return false
        }
    }

    /// Tells the phone the room changed, as the plugin's event does, and waits for it to follow.
    func changed() async {
        event("plugin.household-app.changed", ["rev": .number(Double(room.rev))])
        await eventually("caught up") { self.model.room.rev >= self.room.rev }
    }

    func typing(_ author: String, in conversation: RoomConversation, active: Bool = true) {
        event("plugin.household-app.typing", [
            "conversation": .string(conversation.rawValue),
            "author": .string(author),
            "active": .bool(active),
        ])
    }

    /// One `chat` event of an assistant's reply as it streams.
    func stream(runId: String, in conversation: RoomConversation, seq: Int, state: String, delta: String? = nil) {
        var payload: [String: JSONValue] = [
            "runId": .string(runId),
            "sessionKey": .string(DemoRoom.sessionKeys[conversation] ?? ""),
            "seq": .number(Double(seq)),
            "state": .string(state),
        ]
        if let delta {
            payload["deltaText"] = .string(delta)
        }
        event("chat", payload)
    }

    /// One step of a tool the assistant's run uses, as the gateway sends it to a phone
    /// that follows the conversation.
    func toolStep(_ phase: String, _ name: String, call: String, runId: String, command: String? = nil, in conversation: RoomConversation = .direct) {
        var data: [String: JSONValue] = ["phase": .string(phase), "name": .string(name), "toolCallId": .string(call)]
        if let command {
            data["args"] = .object(["command": .string(command)])
        }
        event("agent", [
            "runId": .string(runId),
            "stream": .string("tool"),
            "seq": .number(1),
            "sessionKey": .string(DemoRoom.sessionKeys[conversation] ?? ""),
            "data": .object(data),
        ])
    }

    /// A tool the assistant's run starts using.
    func toolStarts(_ name: String, in conversation: RoomConversation) {
        toolStep("start", name, call: "call-1", runId: "run-tools", in: conversation)
    }

    func message(_ conversation: RoomConversation, where matches: (RoomMessage) -> Bool) throws -> RoomMessage {
        try XCTUnwrap(model.room.thread(conversation).messages.last(where: matches))
    }

    func eventually(
        _ what: String,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var attemptsLeft = 1000
        while attemptsLeft > 0, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
    }

    private func event(_ name: String, _ payload: [String: JSONValue]) {
        let frame: JSONValue = .object(["type": .string("event"), "event": .string(name), "payload": .object(payload)])
        transport.push((try? JSONEncoder().encode(frame)).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}
#endif
