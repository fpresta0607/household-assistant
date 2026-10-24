#if DEBUG
// The demo: the app talking to the made-up household in DemoRoom instead of a gateway,
// for the preview film and for anyone with a simulator and no gateway. Launch a Debug
// build with `-StewardDemo YES`. It never touches the network, the Keychain or the
// settings a real pairing keeps.
//
// The link comes up the way a gateway's does, then a short scene plays the way the
// approved mockups move: Denise types on the family room's pin and answers, Leo
// replies, Rosa's heart pops on his reply and she reads it, then Leo asks Corey what
// is on tonight and the answer streams in with its follow-ups.
//
// Launched with `-StewardMotionDemo YES` as well, it plays the motion film's scene
// instead (MotionDemoTests): nothing happens until Leo opens his own thread, and then
// Corey streams in tonight's plan with its card and sends a picture, the same every run.

import Foundation

@MainActor
final class DemoGateway: GatewayTransport {
    static let launchArgument = "StewardDemo"
    static let motionArgument = "StewardMotionDemo"
    /// With `-StewardLongThread YES` as well, Leo's own thread holds 150 older messages,
    /// and every message he sends there is answered at length, streamed word by word: the
    /// thread the hitch tests measure (ScrollHitchTests).
    static let longThreadArgument = "StewardLongThread"
    static let threadLayoutArgument = "StewardThreadLayoutDemo"
    /// With `-StewardKeepThreads YES` the demo keeps its conversations on the phone as a
    /// paired phone does, and with `-StewardOffline YES` as well its gateway never answers,
    /// so the threads open from what the run before kept (ChatSpeedTests).
    static let keepThreadsArgument = "StewardKeepThreads"
    static let offlineArgument = "StewardOffline"
    /// With `-StewardNewRowsControl <name>`, Leo's own thread holds 150 older messages,
    /// and each kind of row that joins its bottom arrives on a UI test's cue `<name>.<kind>`
    /// (NewRowsLandInPlaceTests): Corey typing, a reply streaming in, a calendar card, and a
    /// photo kept with no size, whose shape is known only once its picture is; a reply
    /// taller than the screen (ReplyArrivesWholeTests); and three tools done in a blink
    /// before a short reply (ToolStepsHoldTests). Each posts `<name>.<kind>.done` once all
    /// of it has arrived.
    static let newRowsControlArgument = "StewardNewRowsControl"
    private static let newRowKinds = ["typing", "stream", "card", "photo", "longReply", "steps"]
    /// With `-StewardNetworkControl <name>`, the demo's link is cut on a UI test's cue
    /// `<name>.cut`, and opens again only after `<name>.restore` (NetworkCutTests).
    static let networkControlArgument = "StewardNetworkControl"
    /// With `-StewardSharingLocation YES`, Leo shares where he is with Corey and the
    /// family room until midnight (LighterChatsTests).
    static let sharingLocationArgument = "StewardSharingLocation"
    /// With `-StewardDemoClock HH:MM`, the demo household lives as if the app had started at
    /// that time of day today, its clock running on from there, so a UI test that reads where
    /// the time of day puts a row reads the same at any hour it runs (ReplyArrivesWholeTests).
    /// The scene is dated at set times of day, some later today: before those, a reply stamped
    /// now joins the run above it with no time over it. The app's own clock stays real.
    static let clockArgument = "StewardDemoClock"
    static let host = "demo.steward.invalid"

    /// The demo household's clock: the real one, or one set going at `-StewardDemoClock`.
    private static let clock: () -> Date = {
        let parts = (UserDefaults.standard.string(forKey: clockArgument) ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let set = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) else {
            return Date.init
        }
        let offset = set.timeIntervalSinceNow
        return { Date().addingTimeInterval(offset) }
    }()

    private struct Closed: Error {}

    private static var isLongThreadRequested: Bool {
        UserDefaults.standard.bool(forKey: longThreadArgument)
    }

    static var isThreadLayoutRequested: Bool {
        UserDefaults.standard.bool(forKey: threadLayoutArgument)
    }

    nonisolated private static var isOffline: Bool {
        UserDefaults.standard.bool(forKey: offlineArgument)
    }

    private static var newRowsControl: String? {
        UserDefaults.standard.string(forKey: newRowsControlArgument)
    }

    /// The household up to the scene's end, which the film plays.
    let room = DemoRoom(
        now: DemoGateway.clock,
        isFinished: false,
        longThread: DemoGateway.isLongThreadRequested || DemoGateway.newRowsControl != nil ? 150 : 0
    )
    private lazy var settings = DemoSettings(room: room)
    private let phones = DemoPhones()
    private var isOpen = false
    private var inbox: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private var seq = 0
    /// Whether Leo has opened his own thread, which the app says by marking it read.
    private var hasOpenedDirect = false
    /// Whether a UI test has cut the link, which opens again only once it is restored.
    private var isCut = false
    private let threadLayoutControl = UserDefaults.standard.string(forKey: "StewardThreadLayoutControl")
    private var threadLayoutReply: (runId: String, text: String, chunks: [String])?
    private var threadLayoutIncomingMessageId: String?
    private let sendControl: String?
    private var pendingSends: [GatewayRequest] = []

    init(sendControl: String? = UserDefaults.standard.string(forKey: "StewardSendControl")) {
        self.sendControl = sendControl
        if let sendControl {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let gateway = Unmanaged<DemoGateway>.fromOpaque(observer).takeUnretainedValue()
                    Task { @MainActor in
                        let requests = gateway.pendingSends
                        gateway.pendingSends = []
                        for request in requests {
                            gateway.answer(request)
                        }
                    }
                },
                (sendControl + ".keep") as CFString,
                nil,
                .deliverImmediately
            )
        }
        if let newRowsControl = Self.newRowsControl {
            for kind in Self.newRowKinds {
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    Unmanaged.passUnretained(self).toOpaque(),
                    { _, observer, name, _, _ in
                        guard let observer, let name else { return }
                        let gateway = Unmanaged<DemoGateway>.fromOpaque(observer).takeUnretainedValue()
                        let kind = String((name.rawValue as String).split(separator: ".").last ?? "")
                        Task { @MainActor in
                            await gateway.addNewRow(kind)
                        }
                    },
                    (newRowsControl + "." + kind) as CFString,
                    nil,
                    .deliverImmediately
                )
            }
        }
        if let networkControl = UserDefaults.standard.string(forKey: Self.networkControlArgument) {
            for action in ["cut", "restore"] {
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    Unmanaged.passUnretained(self).toOpaque(),
                    { _, observer, name, _, _ in
                        guard let observer, let name else { return }
                        let gateway = Unmanaged<DemoGateway>.fromOpaque(observer).takeUnretainedValue()
                        let isCut = (name.rawValue as String).hasSuffix(".cut")
                        Task { @MainActor in
                            gateway.isCut = isCut
                            if isCut {
                                gateway.closed()
                            }
                        }
                    },
                    (networkControl + "." + action) as CFString,
                    nil,
                    .deliverImmediately
                )
            }
        }
        guard Self.isThreadLayoutRequested, let threadLayoutControl else { return }
        for action in ["incoming", "advance"] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let gateway = Unmanaged<DemoGateway>.fromOpaque(observer).takeUnretainedValue()
                    let isIncoming = (name.rawValue as String).hasSuffix(".incoming")
                    Task { @MainActor in
                        if isIncoming {
                            gateway.threadLayoutIncomingMessageId = gateway.room.say(
                                "About 18 minutes now. Traffic is light.", by: DemoRoom.assistant, in: .direct
                            ).id
                            gateway.changed()
                        } else {
                            gateway.advanceThreadLayoutReply()
                        }
                    }
                },
                (threadLayoutControl + "." + action) as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: launchArgument)
    }

    private static var isMotionRequested: Bool {
        UserDefaults.standard.bool(forKey: motionArgument)
    }

    /// The app's model wired to the demo, with settings kept apart from a real pairing's.
    static func makeModel() -> AppModel {
        let gateway = DemoGateway()
        if DemoLongMessages.isRequested {
            DemoLongMessages.stage(in: gateway.room)
        }
        if DemoCardTaps.isRequested {
            DemoCardTaps.stage(in: gateway.room)
        }
        if DemoContacts.isRequested {
            DemoContacts.stage(in: gateway.room)
        }
        if DemoHeavyThread.isRequested {
            DemoHeavyThread.stage(in: gateway.room)
        }
        if DemoFlingThread.isRequested {
            DemoFlingThread.stage(in: gateway.room)
        }
        if DemoSearchThread.isRequested {
            DemoSearchThread.stage(in: gateway.room)
        }
        if isThreadLayoutRequested {
            gateway.room.say("A short message above the composer.", by: DemoRoom.assistant, in: .direct)
            gateway.room.say(
                "A taller reply wraps onto several lines. The keyboard must leave its text at the same natural height when it rises and falls.",
                by: DemoRoom.assistant, in: .direct
            )
        }
        VoiceNoteTranscripts.shared.remember(DemoRoom.voiceNoteWords, for: gateway.room.voiceNote.id)
        let defaults = UserDefaults(suiteName: "steward-demo") ?? .standard
        defaults.removePersistentDomain(forName: "steward-demo")
        let model = AppModel(
            transport: gateway,
            credentials: DemoCredentials(),
            signer: DeviceSigner(deviceId: "demo-phone", publicKey: "demo-key") { _ in "demo-signature" },
            // The demo is paired already, so it never signs in with Apple.
            applePost: { _, _ in (503, Data()) },
            settings: AppSettings(defaults: defaults),
            mediaDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("steward-demo-media", isDirectory: true),
            // What the person really shares from another app is not the demo's to send.
            shareOutbox: nil,
            shouldAskForPermissions: false,
            shouldAskForContacts: DemoContacts.isRequested,
            roomArchive: UserDefaults.standard.bool(forKey: keepThreadsArgument)
                ? RoomArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent("steward-demo-archive", isDirectory: true))
                : nil
        )
        model.settings.gatewayHost = host
        // The scene is the point of the demo, so its phone has been through the first run.
        model.settings.hasOfferedPermissions = true
        if UserDefaults.standard.bool(forKey: sharingLocationArgument) {
            model.settings.locationSharing = LocationSharing(audience: .family, span: .tonight, from: Date(), calendar: .current)
        }
        if DemoLongMessages.isRequested && DemoLongMessages.isHuman {
            model.settings.reduceMotion = .on
            model.settings.textSize = .xxxLarge
        }
        let isMotion = isMotionRequested
        Task {
            guard !isThreadLayoutRequested, !DemoLongMessages.isRequested, !DemoCardTaps.isRequested, !DemoContacts.isRequested,
                  !DemoHeavyThread.isRequested, !DemoFlingThread.isRequested, !DemoSearchThread.isRequested,
                  newRowsControl == nil, UserDefaults.standard.string(forKey: networkControlArgument) == nil else {
                return
            }
            if isMotion {
                await gateway.playMotion()
            } else {
                await gateway.play(on: model)
            }
        }
        return model
    }

    // MARK: - GatewayTransport

    // The connection calls a socket from away from the main actor too, so each call hops to
    // the main actor, where the demo household lives, first.

    nonisolated func open(_ url: URL) async throws {
        guard !Self.isOffline else {
            throw Closed()
        }
        try await opened()
    }

    nonisolated func send(_ text: String) async throws {
        try await sent(text)
    }

    nonisolated func receive() async throws -> String {
        try await nextFrame()
    }

    /// The connection closes from the main actor.
    nonisolated func close() {
        MainActor.assumeIsolated {
            closed()
        }
    }

    private func opened() throws {
        guard !isCut else {
            throw Closed()
        }
        isOpen = true
        push(.object([
            "type": .string("event"),
            "event": .string("connect.challenge"),
            "payload": .object(["nonce": .string(UUID().uuidString), "ts": .number((Date().timeIntervalSince1970 * 1000).rounded())]),
        ]))
    }

    private func sent(_ text: String) throws {
        guard isOpen else {
            throw Closed()
        }
        let request = try JSONDecoder().decode(GatewayRequest.self, from: Data(text.utf8))
        if let sendControl, request.method == "household-app.send" {
            // Hold storage too, so history or a read notification cannot reveal it early.
            pendingSends.append(request)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName((sendControl + ".pending") as CFString), nil, nil, true
            )
            return
        }
        answer(request)
    }

    private func answer(_ request: GatewayRequest) {
        if request.method == "household-app.read", request.params["conversation"]?.stringValue == RoomConversation.direct.rawValue {
            hasOpenedDirect = true
            // RoomView marks the incoming message read only after observing its ID.
            if let threadLayoutIncomingMessageId, let threadLayoutControl,
               request.params["messageId"]?.stringValue == threadLayoutIncomingMessageId {
                self.threadLayoutIncomingMessageId = nil
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName((threadLayoutControl + ".applied") as CFString), nil, nil, true
                )
            }
        }
        guard let payload = payload(for: request) else {
            push(.object([
                "type": .string("res"),
                "id": .string(request.id),
                "ok": .bool(false),
                "error": .object(["code": .string("INVALID_REQUEST"), "message": .string("unknown method: \(request.method)")]),
            ]))
            return
        }
        let answer: JSONValue = .object(["type": .string("res"), "id": .string(request.id), "ok": .bool(true), "payload": payload])
        push(answer)
        if ["household-app.send", "household-app.react", "household-app.read", "household-app.approval.answer", "household-app.cart.ordered", "household-app.look.set"].contains(request.method) {
            changed()
        }
        if Self.isLongThreadRequested || DemoFlingThread.isRequested, request.method == "household-app.send",
           request.params["conversation"]?.stringValue == RoomConversation.direct.rawValue,
           let asked = request.params["text"]?.stringValue {
            Task {
                await answerAtLength(asked)
            }
        }
    }

    /// Corey's long answer to `asked`, streamed in word by word and then kept, ending with
    /// the question so a test knows its own answer is all in.
    private func answerAtLength(_ asked: String) async {
        let directKey = DemoRoom.sessionKeys[.direct] ?? ""
        await pause(0.4)
        typing(DemoRoom.assistant, in: .direct, active: true)
        await pause(0.6)
        let runId = "demo-run-" + UUID().uuidString.lowercased()
        let reply = DemoFlingThread.isRequested ? DemoFlingThread.reply(to: asked) : "Here is what I found.\n\n- **Morning:** standup at 9, then the school run at 10:15.\n- **Afternoon:** lunch with Rosa at 12:30 and the dentist at 3:30.\n- **Evening:** soccer pickup at 5:45, dinner at home at 6:30.\n\nTraffic should be light all day, and the weather stays dry until late evening, when a little rain moves in. I can set reminders for any of these, move something, or tell Rosa. That was your question \(asked)."
        if Self.isThreadLayoutRequested {
            // The UI test advances the reply only after measuring each incomplete stage.
            threadLayoutReply = (
                runId: runId,
                text: reply,
                chunks: reply.components(separatedBy: "\n\n").enumerated().map { index, paragraph in
                    (index == 0 ? "" : "\n\n") + paragraph
                }
            )
            advanceThreadLayoutReply()
            return
        }
        var isFirst = true
        for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
            chat(runId: runId, sessionKey: directKey, state: "delta", delta: (isFirst ? "" : " ") + word)
            isFirst = false
            await pause(0.04)
        }
        chat(runId: runId, sessionKey: directKey, state: "final", delta: nil)
        typing(DemoRoom.assistant, in: .direct, active: false)
        room.say(reply, by: DemoRoom.assistant, in: .direct)
        changed()
    }

    private func advanceThreadLayoutReply() {
        guard var reply = threadLayoutReply else { return }
        let directKey = DemoRoom.sessionKeys[.direct] ?? ""
        chat(runId: reply.runId, sessionKey: directKey, state: "delta", delta: reply.chunks.removeFirst())
        if reply.chunks.isEmpty {
            threadLayoutReply = nil
            chat(runId: reply.runId, sessionKey: directKey, state: "final", delta: nil)
            typing(DemoRoom.assistant, in: .direct, active: false)
            room.say(reply.text, by: DemoRoom.assistant, in: .direct)
            changed()
        } else {
            threadLayoutReply = reply
        }
    }

    /// One row joining the bottom of Leo's own thread on a UI test's cue, and then
    /// `<control>.<kind>.done` once all of it has arrived and its picture with it.
    private func addNewRow(_ kind: String) async {
        let directKey = DemoRoom.sessionKeys[.direct] ?? ""
        switch kind {
        case "typing":
            typing(DemoRoom.assistant, in: .direct, active: true)
        case "stream":
            typing(DemoRoom.assistant, in: .direct, active: true)
            await pause(0.5)
            let runId = "demo-run-" + UUID().uuidString.lowercased()
            var isFirst = true
            for word in Self.newRowReply.split(separator: " ", omittingEmptySubsequences: false) {
                chat(runId: runId, sessionKey: directKey, state: "delta", delta: (isFirst ? "" : " ") + word)
                isFirst = false
                await pause(0.05)
            }
            chat(runId: runId, sessionKey: directKey, state: "final", delta: nil)
            typing(DemoRoom.assistant, in: .direct, active: false)
            room.say(Self.newRowReply, by: DemoRoom.assistant, in: .direct)
            changed()
        case "card":
            let dinner = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()
            room.say(
                "Dinner is on the calendar:\n\n" + Self.dinnerCard(at: dinner),
                by: DemoRoom.assistant,
                in: .direct,
                did: [DemoRoom.change("event", "added", title: "Dinner at home", at: dinner)]
            )
            changed()
        case "photo":
            let sunset = room.keep(DemoMedia.scene(.sunset, width: 1200, height: 900), kind: .photo, mime: "image/jpeg")
            room.say("", by: DemoRoom.assistant, in: .direct, media: [sunset])
            changed()
        case "longReply":
            typing(DemoRoom.assistant, in: .direct, active: true)
            await pause(0.5)
            await streamReply(Self.longReply, in: directKey, pause: 0.05)
        case "steps":
            typing(DemoRoom.assistant, in: .direct, active: true)
            await pause(0.3)
            let runId = "demo-run-" + UUID().uuidString.lowercased()
            for (index, step) in Self.quickSteps.enumerated() {
                let call = "demo-call-\(index)"
                tool(runId: runId, sessionKey: directKey, phase: "start", name: step.name, call: call, command: step.command)
                await pause(0.06)
                tool(runId: runId, sessionKey: directKey, phase: "result", name: step.name, call: call, command: nil)
                await pause(0.06)
            }
            // Thinking, for longer than the steps take to read.
            await pause(1.8)
            await streamReply(Self.stepsReply, in: directKey, pause: 0.05)
        default:
            return
        }
        await pause(1.5)
        if let control = Self.newRowsControl {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName((control + "." + kind + ".done") as CFString), nil, nil, true
            )
        }
    }

    /// The reply that streams in on a test's cue, long enough to grow over several lines.
    private static let newRowReply = "Here is the day.\n\n- **Morning:** school run at 7:45, then the dentist at 9.\n"
        + "- **Afternoon:** lunch with Rosa at 12:30.\n- **Evening:** soccer pickup at 5:45 and dinner at home at 6:30.\n\n"
        + "The weather stays dry until late, and traffic should be light. That is the whole plan for today."

    /// A reply taller than the screen, as a morning's reading is, streamed in three words at a time.
    private static let longReply = "Here is this morning's reading.\n\n"
        + "**Psalm 23.** The Lord is my shepherd; I shall not want. He makes me lie down in green pastures. "
        + "He leads me beside still waters. He restores my soul. He leads me in paths of righteousness for his name's sake.\n\n"
        + "Even though I walk through the valley of the shadow of death, I will fear no evil, for you are with me; "
        + "your rod and your staff, they comfort me.\n\n"
        + "You prepare a table before me in the presence of my enemies; you anoint my head with oil; my cup overflows.\n\n"
        + "Surely goodness and mercy shall follow me all the days of my life, and I shall dwell in the house of the Lord forever.\n\n"
        + "**To think about today.** A shepherd walks ahead of the flock, so nothing the day brings arrives before he does. "
        + "The table is set in the middle of the trouble, not after it. Where do you need rest today, and where do you need courage?\n\n"
        + "- **Morning:** read it slowly once, out loud if you can.\n"
        + "- **Midday:** pick one line and carry it with you.\n"
        + "- **Evening:** name one way goodness followed you today.\n\n"
        + "I can send you a line from it at noon, or set a reminder for this evening. That is the whole reading for today."

    /// Three tools a run uses in a blink, each named as the gateway names it.
    private static let quickSteps: [(name: String, command: String?)] = [
        ("exec", "gog calendar events --today"),
        ("memory_search", nil),
        ("web_search", nil),
    ]

    /// The short reply after the quick steps.
    private static let stepsReply = "Nothing else is on today, and the weather stays dry. That is all the steps found."

    /// Streams `reply` in from Corey, a few words at a time, then keeps it.
    private func streamReply(_ reply: String, in sessionKey: String, pause seconds: Double) async {
        let runId = "demo-run-" + UUID().uuidString.lowercased()
        let words = reply.split(separator: " ", omittingEmptySubsequences: false)
        for start in stride(from: 0, to: words.count, by: 3) {
            let piece = words[start..<min(start + 3, words.count)].joined(separator: " ")
            chat(runId: runId, sessionKey: sessionKey, state: "delta", delta: (start == 0 ? "" : " ") + piece)
            await pause(seconds)
        }
        chat(runId: runId, sessionKey: sessionKey, state: "final", delta: nil)
        typing(DemoRoom.assistant, in: .direct, active: false)
        room.say(reply, by: DemoRoom.assistant, in: .direct)
        changed()
    }

    private func nextFrame() async throws -> String {
        if !inbox.isEmpty {
            return inbox.removeFirst()
        }
        guard isOpen else {
            throw Closed()
        }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    private func closed() {
        isOpen = false
        threadLayoutReply = nil
        pendingSends = []
        inbox = []
        waiting?.resume(throwing: Closed())
        waiting = nil
    }

    // MARK: - Answers

    private func payload(for request: GatewayRequest) -> JSONValue? {
        switch request.method {
        case "connect":
            return .object([
                "protocol": .number(Double(ConnectRequest.protocolVersion)),
                "features": .object(["methods": .array([]), "events": .array([])]),
                "auth": .object([
                    "role": .string(ConnectRequest.role),
                    "scopes": .array(OperatorScope.chat.map(JSONValue.string)),
                ]),
                // Ticks are not sent, so the phone is told not to expect them.
                "policy": .object(["tickIntervalMs": .number(3_600_000)]),
                "snapshot": .object(["sessionDefaults": .object(["mainSessionKey": .string("agent:main:main")])]),
            ])
        case "agent.identity.get":
            return .object(["agentId": .string("main"), "name": .string("Corey"), "emoji": .string("\u{1F989}")])
        case "household-app.apple.waiting":
            return .object(["waiting": .array([])])
        case "household-app.apple.nonce":
            return .object(["nonce": .string("demo-nonce"), "expiresAtMs": .number(4_102_444_800_000)])
        case DemoToday.method:
            return DemoToday.answer(at: Date())
        case _ where DemoSettings.methods.contains(request.method):
            return settings.answer(request)
        case _ where DemoPhones.methods.contains(request.method):
            return phones.answer(request)
        default:
            return room.answer(request)
        }
    }

    // MARK: - The scene

    private func play(on model: AppModel) async {
        let directKey = DemoRoom.sessionKeys[.direct] ?? ""
        await pause(1.2)
        typing("denise", in: .family, active: true)
        await pause(1.0)
        model.open(.family)
        await pause(1.8)
        typing("denise", in: .family, active: false)
        let flight = room.sayTheFlight()
        room.read(flight.id, by: DemoRoom.person)
        changed()
        await pause(1.6)
        await model.room.send(DemoRoom.pickUpWords, in: .family)
        await pause(1.2)
        if let mine = model.room.family.messages.last(where: { $0.author == DemoRoom.person }) {
            room.react(to: mine.id, by: "gia", with: "\u{2764}\u{FE0F}")
            changed()
            await pause(1.3)
            room.read(mine.id, by: "gia")
            changed()
        }
        await pause(1.2)
        model.path = []
        await pause(0.9)
        model.open(.direct)
        await pause(0.8)
        await model.room.send("What's on tonight?", in: .direct)
        await pause(0.8)
        let runId = "demo-run-" + UUID().uuidString.lowercased()
        typing(DemoRoom.assistant, in: .direct, active: true)
        await pause(1.0)
        let followups = #"{"type":"followups","items":[{"text":"Remind me at 3:45","icon":"reminder"},{"text":"Text Rosa"},{"text":"Add movie night","icon":"calendar"}]}"#
        let reply = "**Tonight**\n- 4:10 PM Rosa lands\n- 6:30 PM Dinner at home\n- 8:00 PM Movie night\n\n"
            + "Want a reminder to leave at 3:45?\n\n```steward-card\n\(followups)\n```"
        var shown = ""
        for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
            let piece = (shown.isEmpty ? "" : " ") + word
            shown += piece
            chat(runId: runId, sessionKey: directKey, state: "delta", delta: piece)
            await pause(0.12)
        }
        chat(runId: runId, sessionKey: directKey, state: "final", delta: nil)
        typing(DemoRoom.assistant, in: .direct, active: false)
        room.say(reply, by: DemoRoom.assistant, in: .direct)
        changed()
    }

    /// The motion film's scene. Once Leo opens his own thread, Corey types, streams in
    /// tonight's plan with dinner as a card, keeps it with the chip saying he put dinner on
    /// the calendar, and then sends a picture of the sunset, which is read from the gateway
    /// the way any new picture is.
    private func playMotion() async {
        while !hasOpenedDirect {
            await pause(0.1)
        }
        let directKey = DemoRoom.sessionKeys[.direct] ?? ""
        let dinner = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()
        await pause(0.6)
        typing(DemoRoom.assistant, in: .direct, active: true)
        await pause(0.9)
        let runId = "demo-run-" + UUID().uuidString.lowercased()
        let reply = "Tonight is easy. Rosa lands at 4:10, and dinner is at home:\n\n" + Self.dinnerCard(at: dinner)
        var isFirst = true
        for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
            chat(runId: runId, sessionKey: directKey, state: "delta", delta: (isFirst ? "" : " ") + word)
            isFirst = false
            await pause(0.12)
        }
        chat(runId: runId, sessionKey: directKey, state: "final", delta: nil)
        typing(DemoRoom.assistant, in: .direct, active: false)
        room.say(reply, by: DemoRoom.assistant, in: .direct, did: [DemoRoom.change("event", "added", title: "Dinner at home", at: dinner)])
        changed()
        await pause(1.4)
        let sunset = room.keep(DemoMedia.scene(.sunset, width: 1200, height: 900), kind: .photo, mime: "image/jpeg", width: 1200, height: 900)
        room.say("", by: DemoRoom.assistant, in: .direct, media: [sunset])
        changed()
    }

    /// Dinner at home from `start`, as the calendar skill writes an event card.
    private static func dinnerCard(at start: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        let end = start.addingTimeInterval(90 * 60)
        let card = #"{"type":"event","title":"Dinner at home","start":"\#(formatter.string(from: start))","end":"\#(formatter.string(from: end))","location":"Home","skill":"calendar"}"#
        return "```steward-card\n\(card)\n```"
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func changed() {
        event("plugin.household-app.changed", ["rev": .number(Double(room.rev))])
    }

    private func typing(_ author: String, in conversation: RoomConversation, active: Bool) {
        event("plugin.household-app.typing", [
            "conversation": .string(conversation.rawValue),
            "author": .string(author),
            "active": .bool(active),
        ])
    }

    private func chat(runId: String, sessionKey: String, state: String, delta: String?) {
        var payload: [String: JSONValue] = [
            "runId": .string(runId),
            "sessionKey": .string(sessionKey),
            "seq": .number(Double(seq + 1)),
            "state": .string(state),
        ]
        if let delta {
            payload["deltaText"] = .string(delta)
        }
        event("chat", payload)
    }

    /// One step of a tool the run uses, as the gateway sends it on the run's `tool` stream.
    private func tool(runId: String, sessionKey: String, phase: String, name: String, call: String, command: String?) {
        var data: [String: JSONValue] = ["phase": .string(phase), "name": .string(name), "toolCallId": .string(call)]
        if let command {
            data["args"] = .object(["command": .string(command)])
        }
        event("agent", [
            "runId": .string(runId),
            "stream": .string("tool"),
            "sessionKey": .string(sessionKey),
            "data": .object(data),
        ])
    }

    private func event(_ name: String, _ payload: [String: JSONValue]) {
        seq += 1
        push(.object(["type": .string("event"), "event": .string(name), "payload": .object(payload), "seq": .number(Double(seq))]))
    }

    private func push(_ frame: JSONValue) {
        guard isOpen, let data = try? JSONEncoder().encode(frame) else {
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: text)
        } else {
            inbox.append(text)
        }
    }
}
#endif
