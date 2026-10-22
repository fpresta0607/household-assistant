// The app's one object graph: settings, the connection, and the screens' models.

import Foundation
import Observation
import UIKit
import UserNotifications
import WidgetKit

@MainActor
@Observable
final class AppModel {
    /// One instance per process, so the Siri intent and a tapped notification talk
    /// through the same connection as the screens.
    static let shared: AppModel = {
        #if DEBUG
        if DemoGateway.isRequested {
            return DemoGateway.makeModel()
        }
        #endif
        return AppModel(
            transport: URLSessionGatewayTransport(),
            credentials: KeychainCredentialStore(),
            signer: DeviceSigner(identity: DeviceIdentityStore.loadOrCreate()),
            roomArchive: RoomArchive(directory: RoomArchive.standardDirectory())
        )
    }()

    let settings: AppSettings
    let connection: GatewayConnection
    /// The family room and this phone's own thread with its assistant. Siri, Talk and
    /// the widget all speak through the thread, so it is one conversation.
    let room: RoomModel
    let media: RoomMediaCache
    let messageSpeech: MessageSpeechPlayer
    /// This phone's own assistant as its gateway holds it, changed from Settings and the
    /// assistant's page, signed like a location report.
    let assistantSettings: AssistantSettingsModel
    /// The assistant's day at a glance, above the pins on Chats.
    let today: TodayModel
    /// Pairing by signing in with Apple, for a phone with no setup code.
    let appleSignIn: AppleSignInPairing
    /// The iPhones waiting for Franco to let them in. Empty on anybody else's phone.
    let signInApprovals: SignInApprovals
    /// This person's iPhones paired to their gateway, for Account.
    let pairedPhones: PairedPhones
    let push = PushRegistration()
    /// What iOS measured of the app each day, for the gateway's log.
    let metrics = MetricsReporter()
    /// When the network is usable again, so the link tries at once.
    let network = NetworkWatcher()
    let permissions: Permissions
    /// Where this phone is, shared with its own assistant while its person chooses.
    let location: LocationSharingModel
    /// The live maps this phone shared in a chat, moved while they last.
    let liveShares: LiveShareModel
    /// The reminders by place this phone watches, set from their cards.
    let placeReminders: PlaceReminders
    /// The ways there the assistant's map cards asked for, worked out on this phone.
    let mapRoutes: MapRoutes
    /// What the person shared from another app, waiting to be sent.
    let shares: ShareInbox
    /// The welcome as the app opens, and App Lock.
    let cover: AppCover

    /// The conversations open over Chats, in the order they were pushed.
    var path: [RoomConversation] = []
    /// The tab on screen: Chats, or Settings, which your own face on Chats also opens.
    var tab = AppTab.chats
    /// The call with the assistant while one is on, whether its screen shows or not. It
    /// lives here, above every screen, so it carries on behind the call bar while the person
    /// moves round the app.
    private(set) var call: TalkViewModel?
    /// Whether the call's screen is up, over everything. Leaving it leaves the call on.
    var isCallShown = false
    /// The conversation whose composer takes the keyboard as it opens, from a widget's
    /// Write button. Its composer clears it.
    var writingIn: RoomConversation?
    /// The conversation whose composer starts a voice note as it opens, from a widget's
    /// microphone. Its composer clears it.
    var recordingIn: RoomConversation?
    /// Who this phone talks to, as the gateway reports it. Nil until it has.
    private(set) var identity: AgentIdentity?
    /// A pairing link opened while this phone is already paired, waiting for the
    /// person to confirm moving it.
    var pendingPairingCode: PairingCode?
    /// Counts the setup codes tried, so the onboarding follows one that arrived as a
    /// link as well as one that was pasted.
    private(set) var pairingAttempt = 0
    /// Whether the connection banner shows: a link coming up is given a few seconds to
    /// come back unseen first.
    private(set) var connectionNotice: ConnectionNotice

    @ObservationIgnored private let credentials: CredentialStore
    /// Mirrors whether the Keychain holds a device token, which nothing can observe.
    private var hasDeviceToken: Bool
    /// The notifications' faces being drawn into the App Group, so the next waits its turn.
    @ObservationIgnored private var drawingFaces: Task<Void, Never>?
    /// What the widgets were last given, so they reload only when what they show changes.
    @ObservationIgnored private var widgetSnapshot = WidgetSnapshot.load()
    @ObservationIgnored private let locationWatcher: LocationWatcher
    @ObservationIgnored private let liveFeed: LiveLocationFeed
    @ObservationIgnored private let placeWatcher: PlaceWatcher
    /// Ends the live maps whose time is up, while the app runs to see it.
    @ObservationIgnored private var liveShareEnd: Task<Void, Never>?
    /// Ends a share when its time is up, while the app runs to see it.
    @ObservationIgnored private var locationEnd: Task<Void, Never>?
    /// Keeps the app running in the background while a position or something shared is sent.
    @ObservationIgnored private var sendingInBackground = UIBackgroundTaskIdentifier.invalid
    /// How many sends are keeping it running, so the first to finish does not stop the rest.
    @ObservationIgnored private var backgroundSends = 0
    /// The one look at the connection notice, when a banner held back is due.
    @ObservationIgnored private var connectionNoticeLook: Task<Void, Never>?
    /// What iOS measured, waiting for the gateway to be connected to hear it.
    @ObservationIgnored private var unsentMetrics: [PhoneMetrics] = []

    /// The phone hands in its socket, its Keychain and its key pair; the
    /// screenshot test hands in the captured fixtures and an in-memory store,
    /// so every screen can be put into every state the gateway can put it into.
    /// `applePost` is how a phone with no pairing reaches a gateway to sign in, and
    /// `shareOutbox` where the Share Extension leaves what was shared.
    /// `connectionNoticeDelay` is how long a link may be coming up before the banner
    /// says so; the screenshots draw each state as it looks once it does.
    /// `roomArchive` is where this phone keeps its conversations to open them at once and
    /// offline; the tests keep none, and the demo only when asked (DemoGateway).
    /// `shouldAskForContacts` lets the demo alone read and ask for Contacts, nil follows
    /// `shouldAskForPermissions`.
    init(
        transport: GatewayTransport,
        credentials: CredentialStore,
        signer: DeviceSigner,
        applePost: @escaping AppleSignInGateway.Post = AppleSignInBridge.post,
        settings: AppSettings = AppSettings(),
        mediaDirectory: URL = RoomMediaCache.standardDirectory(),
        shareOutbox: ShareOutbox? = ShareFolder.outbox,
        shouldAskForPermissions: Bool = true,
        shouldAskForContacts: Bool? = nil,
        connectionNoticeDelay: Double = ConnectionNotice.delaySeconds,
        roomArchive: RoomArchive? = nil
    ) {
        self.credentials = credentials
        self.settings = settings
        hasDeviceToken = credentials.deviceToken != nil
        connectionNotice = ConnectionNotice(delaySeconds: connectionNoticeDelay)
        // The screenshot tests and the demo have nobody to answer iOS's questions.
        permissions = Permissions(
            isAllowedToAsk: shouldAskForPermissions,
            isAllowedToAskForContacts: shouldAskForContacts ?? shouldAskForPermissions
        )
        let connection = GatewayConnection(transport: transport, credentials: credentials, signer: signer)
        self.connection = connection
        room = RoomModel(connection: connection, sign: signer.sign, archive: roomArchive)
        media = RoomMediaCache(connection: connection, directory: mediaDirectory)
        messageSpeech = MessageSpeechPlayer(connection: connection, media: media)
        assistantSettings = AssistantSettingsModel(connection: connection, sign: signer.sign, spendStore: settings)
        today = TodayModel(connection: connection, archive: roomArchive, seen: settings)
        appleSignIn = AppleSignInPairing(credentials: credentials) { member in
            AppleSignInGateway(base: member.gateway, post: applePost)
        }
        signInApprovals = SignInApprovals(connection: connection, sign: signer.sign)
        pairedPhones = PairedPhones(connection: connection, sign: signer.sign)
        location = LocationSharingModel(connection: connection, sign: signer.sign, store: settings)
        liveShares = LiveShareModel(connection: connection, sign: signer.sign, store: settings)
        placeReminders = PlaceReminders(store: settings)
        mapRoutes = MapRoutes(find: RouteFinder.route(to:))
        shares = ShareInbox(outbox: shareOutbox)
        cover = AppCover(settings: settings)
        locationWatcher = LocationWatcher(isAllowedToWatch: shouldAskForPermissions)
        liveFeed = LiveLocationFeed(isAllowedToFollow: shouldAskForPermissions)
        placeWatcher = PlaceWatcher(isAllowedToWatch: shouldAskForPermissions)

        // The widgets show the last known assistant until the gateway answers.
        if let name = widgetSnapshot.assistantName {
            identity = AgentIdentity(agentId: "", name: name, emoji: widgetSnapshot.assistantEmoji)
        }

        connection.onEvent = { [weak self] event in
            self?.room.handle(event)
            self?.today.handle(event)
        }
        connection.onConnected = { [weak self] in
            self?.hasDeviceToken = true
            Task {
                await self?.refreshAfterConnect()
            }
        }
        room.onParticipantsChanged = { [weak self] in
            self?.drawNotificationFaces()
        }
        room.prepare = { [weak room] messages in
            guard let room else {
                return
            }
            await MarkdownDocuments.prepare(messages, participants: room.participants, me: room.me)
        }
        // The conversations as this phone kept them, before the gateway answers or when it
        // cannot, each answer parsed ahead so its bubble has its full height at once.
        if roomArchive != nil {
            Task { [room] in
                await room.restore()
                for conversation in RoomConversation.allCases {
                    await MarkdownDocuments.prepare(room.thread(conversation).messages, participants: room.participants, me: room.me)
                }
            }
        }
        room.onSent = { [weak self] conversation in
            self?.suggest(conversation)
        }
        shares.onPosted = { [weak self] in
            self?.collectShares()
        }
        push.onToken = { [weak self] in
            Task {
                await self?.registerForPush()
            }
        }
        network.onUsable = { [weak self] in
            self?.connection.retryNow()
        }
        metrics.onReport = { [weak self] reports in
            self?.unsentMetrics += reports
            Task {
                await self?.sendMetrics()
            }
        }
        location.onChange = { [weak self] in
            self?.followLocation()
        }
        locationWatcher.onFix = { [weak self] fix in
            self?.share(fix)
        }
        locationWatcher.onDenied = { [weak self] in
            Task {
                await self?.location.stop()
            }
        }
        liveShares.onChange = { [weak self] in
            self?.followLiveShares()
        }
        liveFeed.onFix = { [weak self] fix in
            self?.moveLiveShares(fix)
        }
        placeReminders.onChange = { [weak self] in
            self?.watchPlaces()
        }
        placeWatcher.onSeen = { [weak self] id, isInside in
            self?.seen(id, isInside: isInside)
        }
        NotificationCategories.register(assistantName: assistantName)
        followConnection()
        followForWidgets()
        followLocation()
        followLiveShares()
        // As the app starts, whatever it starts for: a place crossed while it was closed is
        // heard only once the same monitor is open again.
        watchPlaces()
    }

    /// The name the assistant's page shows and changes, the same everywhere at once: what
    /// its gateway's settings say, a rename on its way included, before the identity read
    /// when the phone connected.
    var assistantName: String {
        assistantSettings.name ?? identity?.name ?? "your assistant"
    }

    /// The other person in the family room, by name.
    var otherPersonName: String {
        room.participants.first { $0.kind == .person && !$0.isOwner }?.name ?? "the family"
    }

    /// The other household's assistant, for "checking with Denise".
    var otherAssistantName: String? {
        room.participants.first { $0.kind == .assistant && $0.id != room.me?.assistant }?.name
    }

    /// This phone's assistant's face, once somebody has chosen one.
    var assistantPhoto: RoomMedia? {
        room.me.flatMap { room.participant($0.assistant)?.avatar }
    }

    /// The ring this phone's person picked for their assistant's face, nil while it is gold.
    var assistantRing: RingColor? {
        room.me.flatMap { settings.assistantRings[$0.assistant] }
    }

    /// Connects with whatever is stored. Safe to call again; it restarts the link.
    func connect() {
        guard let url = GatewayAddress.url(from: settings.gatewayHost) else {
            connection.stop()
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        connection.start(GatewayConnection.Configuration(
            url: url,
            client: .stewardPhone(displayName: "Steward AI on iPhone", version: version),
            scopes: OperatorScope.chat,
            locale: Locale.current.identifier
        ))
    }

    /// The app came to the front or went to the back. A link still coming up as it comes
    /// back gets its few seconds from then before the banner says so.
    func appMoved(toFront: Bool) {
        connectionNotice.moved(toFront: toFront, at: Date())
        lookAtConnectionNoticeWhenDue()
        if toFront {
            today.updateClock()
            connection.retryNow()
        }
    }

    /// Keeps the banner's notice in step with every state the link moves to.
    private func followConnection() {
        let state = withObservationTracking {
            connection.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followConnection()
            }
        }
        connectionNotice.saw(state, at: Date())
        lookAtConnectionNoticeWhenDue()
    }

    /// Looks at the notice once, when a banner held back is due, rather than on a timer.
    private func lookAtConnectionNoticeWhenDue() {
        connectionNoticeLook?.cancel()
        guard let due = connectionNotice.dueAt else {
            return
        }
        connectionNoticeLook = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else {
                return
            }
            self?.connectionNotice.look(at: Date())
        }
    }

    /// Whether this phone is paired: it holds its own token for a gateway it knows.
    /// Until it is, the onboarding shows instead of Chats.
    var isPaired: Bool {
        hasDeviceToken && GatewayAddress.url(from: settings.gatewayHost) != nil
    }

    /// Pairs this phone from a setup code: the gateway it names and its single-use token.
    func pair(_ code: PairingCode) {
        pendingPairingCode = nil
        settings.gatewayHost = code.url.absoluteString
        forgetAssistant()
        credentials.deviceToken = nil
        hasDeviceToken = false
        credentials.bootstrapToken = code.bootstrapToken
        pairingAttempt += 1
        connect()
    }

    /// Pairs from the setup code a sign-in with Apple earned, whose Apple ID the gateway
    /// already knows as this person's.
    func pairSignedInWithApple(_ code: PairingCode) {
        pair(code)
        settings.hasLinkedAppleID = true
    }

    /// For Siri, which may have started the app in the background with no screen.
    func ask(_ question: String) async throws -> String {
        try await awaitRoom()
        return try await room.ask(question)
    }

    /// A text he got, handed over by a Shortcuts automation or Siri, which may have started
    /// the app in the background with no screen: it goes to his own thread, where his
    /// assistant drafts the reply as a message card for him to send. Answers whether the
    /// gateway kept it.
    func draftReply(to text: ReceivedText) async throws -> Bool {
        try await awaitRoom()
        return await room.send(text.request, in: .direct)
    }

    /// The Contacts connector as its switch and iOS have it.
    var contactsConnector: ContactsConnector {
        ContactsConnector(isOn: settings.shouldLookInContacts, access: permissions.state(of: .contacts))
    }

    /// Connectors on: the gateway's, and Contacts on this iPhone.
    var connectorsOn: Int {
        assistantSettings.connectorsOn + (contactsConnector.isConnected ? 1 : 0)
    }

    /// Turns sharing on from the first run or Settings. Sharing that lasts asks iOS for
    /// Always (LocationAlwaysAsk), so it goes on with the app closed: on a first ask iOS
    /// shows only its While Using question, and offers Always by itself later. Sharing
    /// starts only if iOS allows location at all; a no to Always keeps it sharing while the
    /// app is open, and Location says so.
    func shareLocation(with audience: LocationAudience, for span: LocationSpan) async {
        if LocationAlwaysAsk.isAsked(at: .sharingTurnedOn(span)) {
            await permissions.requestAlways()
        } else {
            await permissions.request(.location)
        }
        guard permissions.status(of: .location) == .allowed else {
            return
        }
        await location.start(with: audience, for: span)
    }

    private func askForAlways(at moment: LocationAlwaysAsk.Moment) async {
        if LocationAlwaysAsk.isAsked(at: moment) {
            await permissions.requestAlways()
        }
    }

    /// Steward AI's own Precise Location switch. Turned on, it asks iOS for precise too when
    /// iOS gives only the area.
    func sharePrecisely(_ isPrecise: Bool) async {
        await location.share(precisely: isPrecise)
        if isPrecise {
            await permissions.askForPrecise()
        }
    }

    /// What the assistant gets now: precise, approximate by choice, or kept approximate by iOS.
    var locationPrecision: LocationPrecision {
        LocationPrecision(
            isWanted: location.isPrecise,
            isPreciseInIOS: permissions.isLocationPrecise,
            isAllowed: permissions.status(of: .location) == .allowed
        )
    }

    /// Whether this iPhone shares where it is, as Settings, Account and Location all say it.
    var locationState: LocationState {
        LocationState(
            permission: permissions.status(of: .location),
            sharing: location.sharing,
            isHeldByGateway: location.isHeldByGateway
        )
    }

    /// Watches where the phone is exactly while it shares, with a fresh position each time,
    /// and ends the share when its time is up. Safe to call again: iOS may have started the
    /// app in the background to say it moved, and watching again is what hands that over.
    func followLocation() {
        let sharing = location.sharing
        locationWatcher.follow(isSharing: location.isSending)
        locationEnd?.cancel()
        guard let until = sharing?.until, sharing?.isPaused == false else {
            return
        }
        locationEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled else {
                return
            }
            await self?.location.endIfOver()
        }
    }

    // MARK: - Maps in a chat

    /// Shares where this phone is as a map in `conversation`, once or live for `span`.
    /// iOS is asked for While Using the first time. Answers why not in words a person can
    /// read, or nil once the map is on its way, where a send that fails says so itself.
    func shareMap(in conversation: RoomConversation, for span: MapShareSpan) async -> String? {
        await permissions.request(.location)
        guard permissions.status(of: .location) == .allowed else {
            return "Allow Location for Steward AI in Settings to share where you are."
        }
        guard let measured = await liveFeed.current() else {
            return "Your iPhone could not find where you are just now."
        }
        let fix = settings.isLocationPrecise ? measured : measured.approximated
        let until = span.until(from: Date(), calendar: .current)
        let location = SharedLocation(position: fix.position, until: until.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) })
        guard let kept = await room.share(location, in: conversation), let until else {
            return nil
        }
        liveShares.start(LiveShare(messageId: kept.id, conversation: conversation, until: until), at: fix, sentAt: kept.at)
        await askForAlways(at: .mapShared(span))
        return nil
    }

    func stopMapShare(_ messageId: String) async {
        await liveShares.stop(messageId)
    }

    /// Follows where the phone is exactly while a live map lasts, and ends each when its
    /// time is up.
    private func followLiveShares() {
        liveFeed.follow(liveShares.isFollowing)
        liveShareEnd?.cancel()
        guard let next = liveShares.shares.map(\.until).min() else {
            return
        }
        liveShareEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else {
                return
            }
            self?.liveShares.endIfOver()
        }
    }

    private func moveLiveShares(_ fix: LocationFix) {
        keepRunningToSend()
        Task {
            await liveShares.consider(fix)
            stopRunningToSend()
        }
    }

    // MARK: - Reminders by place

    /// Sets this person's own reminder by place from its card: iOS is asked for Always,
    /// and for notifications if it never was, and this phone watches the place from now on.
    func setPlaceReminder(_ card: PlaceReminderCard, in messageId: String) async {
        await askForAlways(at: .placeReminderSet)
        if permissions.status(of: .notifications) == .notAsked {
            await permissions.request(.notifications)
        }
        placeReminders.watch(PlaceWatch(card, id: messageId, repliesInRoom: false))
    }

    /// This person's yes or no to another assistant's reminder by place that would watch
    /// them. After a yes this phone watches the place and says in the family room when it
    /// happens; after a no it watches it no more.
    func answerPlaceReminder(_ card: PlaceReminderCard, in messageId: String, with answer: PlaceAnswer) async {
        guard await room.answerPlace(messageId, with: answer) else {
            return
        }
        switch answer {
        case .yes:
            await askForAlways(at: .placeReminderSet)
            placeReminders.watch(PlaceWatch(card, id: messageId, repliesInRoom: true))
        case .no:
            placeReminders.unwatch(messageId)
        }
    }

    private func watchPlaces() {
        let watches = placeReminders.watches
        Task {
            await placeWatcher.watch(watches)
        }
    }

    /// iOS saw the person on one side of a watched place. A reminder that goes off says so
    /// in a notification, or, watched for somebody else, in the family room as a reply to
    /// its card, which the asking assistant answers. iOS may have woken the app for it.
    private func seen(_ id: String, isInside: Bool) {
        guard let watch = placeReminders.saw(id, isInside: isInside) else {
            return
        }
        guard watch.repliesInRoom else {
            remind(watch)
            return
        }
        keepRunningToSend()
        Task {
            try? await awaitRoom()
            if !(await room.send(watch.reply, in: .family, replyTo: watch.id)) {
                tellNotSent(watch.reply, in: .family)
            }
            stopRunningToSend()
        }
    }

    /// A reminder by place going off, from this phone's assistant, in its own thread.
    private func remind(_ watch: PlaceWatch) {
        let content = UNMutableNotificationContent()
        content.title = assistantName
        content.subtitle = watch.happened
        content.body = watch.text
        content.sound = .default
        content.threadIdentifier = RoomConversation.direct.rawValue
        content.userInfo = [NotificationPayload.conversationKey: RoomConversation.direct.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "place-" + watch.id, content: content, trigger: nil))
    }

    /// A position from iOS, perhaps with the app in the background, where iOS gives it a
    /// few seconds: asking for a little more keeps it running until the report is sent.
    private func share(_ fix: LocationFix) {
        keepRunningToSend()
        Task {
            try? await awaitRoom()
            await location.consider(fix)
            stopRunningToSend()
        }
    }

    private func keepRunningToSend() {
        backgroundSends += 1
        guard sendingInBackground == .invalid else {
            return
        }
        sendingInBackground = UIApplication.shared.beginBackgroundTask(withName: "Sending") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    private func stopRunningToSend() {
        backgroundSends = max(backgroundSends - 1, 0)
        if backgroundSends == 0 {
            endBackgroundTime()
        }
    }

    /// Whatever did not go out before iOS stopped the app is sent when the link is next up.
    private func endBackgroundTime() {
        guard sendingInBackground != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(sendingInBackground)
        sendingInBackground = .invalid
    }

    /// What was shared from another app: shown in its conversation at once, and sent as
    /// soon as the room knows who this phone is. The Share Extension's word that one is
    /// ready, the app coming to the front and the link coming up each look.
    func collectShares() {
        shares.look()
        Task {
            await sendShares()
        }
    }

    /// The person may open the app only for a moment, so it asks to keep running until
    /// what was shared is sent. What is left for later stays in the App Group.
    private func sendShares() async {
        shares.look()
        guard !shares.waiting.isEmpty else {
            return
        }
        keepRunningToSend()
        defer {
            stopRunningToSend()
        }
        try? await awaitRoom()
        guard connection.state == .connected, room.me != nil else {
            return
        }
        await shares.send(through: room)
    }

    /// Puts the conversation the person just wrote in at the front of the Share Sheet.
    private func suggest(_ conversation: RoomConversation) {
        guard let me = room.me else {
            return
        }
        ShareSuggestions.donate(conversation, participants: room.participants, me: me)
    }

    /// What the person did with a notification. A tap opens its conversation. A reply or
    /// a reaction is sent the way the composer and the reaction bar send it, a family
    /// message signed by this phone. iOS may have woken the app in the background for it,
    /// so the link comes up first, and one that does not go through is said in a
    /// notification of its own, since nobody is looking at the room.
    func answer(_ answer: NotificationAnswer) async {
        switch answer {
        case .open(let conversation):
            open(conversation)
        case .reply(let text, to: let messageId, in: let conversation):
            try? await awaitRoom()
            let isSent = await room.send(text, in: conversation, replyTo: messageId)
            if !isSent {
                tellNotSent(text, in: conversation)
            }
        case .react(let emoji, to: let messageId, in: let conversation):
            try? await awaitRoom()
            let isSent = await room.react(to: messageId, with: emoji, in: conversation)
            if !isSent {
                tellNotSent(emoji, in: conversation)
            }
        }
    }

    /// Brings the link up when it is down, and waits up to ten seconds for the room to
    /// know who this phone is: the app may have been started in the background with no
    /// screen, by Siri or a notification.
    private func awaitRoom() async throws {
        if connection.state == .disconnected {
            connect()
        }
        var attemptsLeft = 100
        while attemptsLeft > 0, connection.state.isComingUp || (connection.state == .connected && room.me == nil) {
            try await Task.sleep(for: .milliseconds(100))
            attemptsLeft -= 1
        }
    }

    /// What did not reach the gateway from a notification, said where the person will see
    /// it. Tapping it opens the conversation.
    private func tellNotSent(_ what: String, in conversation: RoomConversation) {
        let content = UNMutableNotificationContent()
        content.title = "Not sent to \(NotificationActions.name(of: conversation, assistantName: assistantName))"
        content.body = what
        content.threadIdentifier = conversation.rawValue
        content.userInfo = [NotificationPayload.conversationKey: conversation.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func forgetPairing() {
        connection.stop()
        credentials.deviceToken = nil
        credentials.bootstrapToken = nil
        hasDeviceToken = false
        forgetAssistant()
    }

    /// Opens a conversation from anywhere: a tapped notification, a widget, Siri. A call
    /// going on carries on behind the call bar.
    func open(_ conversation: RoomConversation) {
        tab = .chats
        isCallShown = false
        path = [conversation]
    }

    /// Calls the assistant, from a Call button, a widget, the Talk control or Siri, or brings
    /// back the call already going on.
    func callAssistant() {
        if call == nil {
            messageSpeech.stop()
            let call = TalkViewModel(
                room: room,
                connection: connection,
                voice: TalkVoice(connection: connection, media: media),
                holdingLines: HoldingLines(connection: connection, media: media, record: HoldingLines.standardRecord()),
                isReadingAloud: settings.shouldReadRepliesAloud,
                assistantName: assistantName
            )
            call.onClosed = { [weak self, weak call] in
                guard let self, let call, self.call === call else {
                    return
                }
                self.call = nil
                self.isCallShown = false
            }
            self.call = call
            call.begin()
        }
        isCallShown = true
    }

    /// Opens the place a widget or the Talk control links to. Talk needs a paired phone,
    /// and would otherwise come up the moment the onboarding gave way to Chats.
    func open(_ link: AppLink) {
        switch link {
        case .conversation(let conversation):
            open(conversation)
        case .write(let conversation):
            open(conversation)
            writingIn = conversation
        case .record(let conversation):
            open(conversation)
            // Like Talk, a note never starts the moment the onboarding gives way.
            if isPaired {
                recordingIn = conversation
            }
        case .talk:
            guard isPaired else {
                return
            }
            callAssistant()
        }
    }

    /// Everything this phone knows about the assistant it was talking to, in one
    /// place: the conversations, its settings, its day, who the gateway said it was, the
    /// snapshot the widget renders from its own process, what waits to be sent from the
    /// Share Sheet and the suggestions in it. Pairing to a different gateway and
    /// forgetting a pairing both go through here.
    private func forgetAssistant() {
        messageSpeech.stop()
        // A call with the assistant being forgotten ends with it.
        call?.hangUp()
        room.reset()
        path = []
        // Pairing again starts from Settings, and the new pairing opens on its chats.
        tab = .chats
        assistantSettings.reset()
        today.reset()
        signInApprovals.reset()
        pairedPhones.reset()
        location.reset()
        liveShares.reset()
        placeReminders.reset()
        mapRoutes.reset()
        shares.forget()
        ShareSuggestions.forget()
        // A linked Apple ID belongs to the gateway it was linked on.
        settings.hasLinkedAppleID = false
        identity = nil
        publishWidgets(WidgetSnapshot())
        afterFaces {
            NotificationFaces.forget()
        }
    }

    /// Draws the faces the notification extension shows, for who is in the room now. The
    /// widgets show the same faces, so they reload once they are drawn.
    private func drawNotificationFaces() {
        guard let me = room.me else {
            return
        }
        let participants = room.participants
        afterFaces {
            await NotificationFaces.save(participants, me: me, media: self.media)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Keeps the widgets' snapshot in step with the room and the assistant: it is made
    /// again after any change to what it reads, and written only when it differs. It reads
    /// only what the gateway has kept of each conversation, all a widget shows, so a reply
    /// streaming in does not make it again. Until the room has said who this phone is, the
    /// lines last written stay, so a cold start with no link does not blank the widgets.
    private func followForWidgets() {
        let snapshot = withObservationTracking {
            var next = widgetSnapshot
            next.assistantName = assistantSettings.name ?? identity?.name
            next.assistantEmoji = identity?.emoji
            if let me = room.me {
                next.show(
                    family: room.kept(.family),
                    direct: room.kept(.direct),
                    participants: room.participants,
                    me: me,
                    rings: settings.assistantRings
                )
            }
            return next
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followForWidgets()
            }
        }
        publishWidgets(snapshot)
    }

    private func publishWidgets(_ snapshot: WidgetSnapshot) {
        guard snapshot != widgetSnapshot else {
            return
        }
        widgetSnapshot = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Runs after whatever is being drawn into the App Group, so the newest is written last.
    private func afterFaces(_ work: @escaping @MainActor () async -> Void) {
        let previous = drawingFaces
        drawingFaces = Task {
            await previous?.value
            await work()
        }
    }

    /// Runs once the link is up: who am I talking to, what was said meanwhile, the
    /// assistants' answers parsed ahead of their threads, the Today card, where this phone's
    /// notifications go, whatever about where it is did not get through, and what was
    /// shared from another app while the link was down.
    private func refreshAfterConnect() async {
        if let identity = try? await connection.agentIdentity() {
            self.identity = identity
            NotificationCategories.register(assistantName: assistantName)
        }
        await room.refresh()
        // Before either thread is opened, so it opens with every bubble at its full height.
        for conversation in RoomConversation.allCases {
            await MarkdownDocuments.prepare(room.thread(conversation).messages, participants: room.participants, me: room.me)
        }
        await today.refresh()
        await registerForPush()
        await signInApprovals.refresh()
        await location.catchUp()
        await sendShares()
        await sendMetrics()
    }

    private func registerForPush() async {
        guard connection.state == .connected, let registration = push.registration else {
            return
        }
        try? await connection.roomRegisterPush(
            token: registration.token,
            environment: registration.environment,
            key: registration.key
        )
    }

    /// Each day is sent once: a gateway from before build 14 has no method for it, and a
    /// day it turned down would be turned down again.
    private func sendMetrics() async {
        guard connection.state == .connected, !unsentMetrics.isEmpty else {
            return
        }
        let reports = unsentMetrics
        unsentMetrics = []
        for report in reports {
            try? await connection.reportPhoneMetrics(report)
        }
    }

    func open(_ url: URL) {
        if let code = PairingCode(text: url.absoluteString) {
            // A link never moves a paired phone by itself: a stray one could point
            // it at somebody else's gateway.
            if isPaired {
                pendingPairingCode = code
            } else {
                pair(code)
            }
        } else if let link = AppLink(url: url) {
            open(link)
        }
    }
}

