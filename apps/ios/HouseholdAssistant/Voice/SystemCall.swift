// The call with the assistant as iOS knows it, through CallKit: a real phone call, so it
// shows in the green pill, on the Lock Screen and in the Dynamic Island, AirPods mute it
// and end it, and in the car it plays through CarPlay. The caller is the assistant, by
// name.
//
// iOS owns a call's sound. The call asks iOS to start, its sound is set up for voice chat
// as iOS takes it (AudioFocus), and iOS makes that sound active and says so: only then
// does the microphone run (TalkViewModel). iOS takes the sound away again for a phone call
// the person holds ours for, and says that too. Muting and ending go through iOS, from the
// call's own screen as much as from AirPods, the Lock Screen or the car, so all of them
// always agree. Muting is the person's microphone only: the assistant finishes what it is
// saying (TalkSession). The call reports it is connecting as iOS takes it, and connected
// once the gateway's link is up as well (CallState), which starts the time on the pill.
//
// One provider at a time serves every call, as CallKit expects. It is made for the first
// call, and made afresh after iOS resets it, since a provider iOS has reset refuses every
// call after. The calls stay out of the Phone app's Recents: the thread already keeps each
// call as one row, and a Recents entry would call back through an intent this app does not
// take. On the Simulator, where CallKit cannot run a call, and for a call iOS refuses or
// resets before it has its sound (CallPlacement), the call makes its sound active itself
// and gives it back after, as Telegram does.

import AVFoundation
import CallKit

@MainActor
final class SystemCall: NSObject, CXProviderDelegate {
    /// iOS made the call's sound active, or took it away.
    var onAudio: ((Bool) -> Void)?
    /// The microphone was muted or unmuted, from the call's screen, AirPods or the Lock Screen.
    var onMuted: ((Bool) -> Void)?
    /// iOS put the call on hold for a phone call the person took, or took it off.
    var onHeld: ((Bool) -> Void)?
    /// The call ended, wherever it was ended. Told once.
    var onEnded: (() -> Void)?
    /// The call could not have the sound, as a sentence to show.
    var onRefused: ((String) -> Void)?

    /// How the call got its sound, for its record.
    private(set) var placement = CallPlacement()

    /// The provider serving calls now. Nil before the first call and after a reset.
    private static var provider: CXProvider?

    private static let hasCallKit: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }()

    private static let giveBackAttempts = 5
    private static let giveBackRetry = Duration.milliseconds(250)

    private let id = UUID()
    private let callerName: String
    private let controller = CXCallController()
    private var isStarted = false
    private var isEnded = false
    private var isMuted = false
    /// Whether the call set the sound up for itself, so it has something to give back.
    private var isSoundTaken = false
    private var isAudioActive = false

    init(callerName: String) {
        self.callerName = callerName
        super.init()
    }

    /// Places the call, once. A call whose sound could not be started may be placed again,
    /// and goes the same way: through CallKit, or in the app.
    func start() {
        guard !isStarted, !isEnded else {
            return
        }
        isStarted = true
        guard placement.handle(.placed(hasCallKit: Self.hasCallKit)) != .takeTheSound else {
            takeTheSound()
            return
        }
        let provider = Self.provider ?? Self.makeProvider()
        Self.provider = provider
        provider.setDelegate(self, queue: nil)
        let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: callerName))
        controller.request(CXTransaction(action: start)) { [weak self] error in
            let refusal = error.map { ($0 as NSError).code }
            Task { @MainActor in
                self?.startAnswered(refusal: refusal)
            }
        }
    }

    /// The call connected: iOS runs its time from `moment`.
    func connected(at moment: Date) {
        guard isStarted, !isEnded, placement.isThroughCallKit else {
            return
        }
        Self.provider?.reportOutgoingCall(with: id, connectedAt: moment)
    }

    /// Mutes or unmutes the microphone through iOS, which then tells `onMuted`, so the Lock
    /// Screen and the call's screen agree. Before iOS has the call, without CallKit, or should
    /// iOS not answer, it is done here.
    func setMuted(_ isMuted: Bool) {
        guard isStarted, !isEnded, placement.isThroughCallKit else {
            self.isMuted = isMuted
            onMuted?(isMuted)
            return
        }
        requestMute(isMuted)
    }

    /// Ends the call, from its screen or the word "stop": iOS ends it everywhere, then tells
    /// `onEnded`. Before iOS has the call, without CallKit, or should iOS not answer, it ends
    /// here.
    func end() {
        guard !isEnded else {
            return
        }
        guard isStarted, placement.isThroughCallKit else {
            ended()
            return
        }
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
            let isRefused = error != nil
            Task { @MainActor in
                if isRefused {
                    self?.endedWithoutIOS()
                }
            }
        }
    }

    private static func makeProvider() -> CXProvider {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        return CXProvider(configuration: configuration)
    }

    // MARK: - iOS answering

    /// iOS took the call, or refused it with `refusal`, its error's code: a refused call
    /// takes the sound itself and goes on.
    private func startAnswered(refusal: Int?) {
        guard isStarted, !isEnded else {
            return
        }
        if let refusal {
            // A reset between calls tells no call, since none is the delegate then, so a
            // provider that refused is made afresh for the next call as a reset one is.
            Self.provider?.invalidate()
            Self.provider = nil
            follow(placement.handle(.refused(code: refusal)))
            return
        }
        // A reset may have moved the call into the app before iOS answered.
        guard placement.isThroughCallKit else {
            return
        }
        // The name iOS shows for the call, on the pill, the Lock Screen and in the car.
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        // So a phone call coming in offers to hold this one, which goes on after.
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        Self.provider?.reportCall(with: id, updated: update)
        // Muted before iOS had the call, so iOS shows it muted as well.
        if isMuted {
            requestMute(true)
        }
    }

    /// Does what the placement decided once iOS answered.
    private func follow(_ effect: CallPlacement.Effect) {
        switch effect {
        case .none:
            break
        case .takeTheSound:
            takeTheSound()
        case .end:
            isAudioActive = false
            ended()
        }
    }

    private func requestMute(_ isMuted: Bool) {
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: isMuted))) { [weak self] error in
            let isRefused = error != nil
            Task { @MainActor in
                guard isRefused, let self, !self.isEnded else {
                    return
                }
                self.isMuted = isMuted
                self.onMuted?(isMuted)
            }
        }
    }

    private func endedWithoutIOS() {
        guard !isEnded else {
            return
        }
        Self.provider?.reportCall(with: id, endedAt: Date(), reason: .failed)
        ended()
    }

    /// The call is over, whoever ended it. Its sound is anyone's again at once: the
    /// microphone and the voice have stopped by the time this returns. With CallKit, iOS
    /// makes the sound inactive a moment later, and the app's resting sound comes back then.
    private func ended() {
        guard !isEnded else {
            return
        }
        isEnded = true
        onEnded?()
        guard isSoundTaken else {
            return
        }
        AudioFocus.callEnded()
        if !placement.isThroughCallKit {
            giveTheSoundBack()
        } else if !isAudioActive {
            AudioFocus.rest()
        }
    }

    // MARK: - Without CallKit

    private func takeTheSound() {
        do {
            try AudioFocus.takeForCall(activating: true)
        } catch {
            AudioFocus.callEnded()
            AudioFocus.rest()
            couldNotHaveTheSound()
            return
        }
        isSoundTaken = true
        isAudioActive = true
        onAudio?(true)
    }

    /// The microphone could not be started: a tap places the call again, the way it went.
    private func couldNotHaveTheSound() {
        isStarted = false
        onRefused?("The microphone could not be started.")
    }

    /// The engine and the voice tear their sound down a moment after they stop, and a sound
    /// still running refuses to be given back, so a refusal is tried again over about a
    /// second rather than leaving other apps' sound off for good. A last failure is not
    /// reported: the call is gone, and there is nowhere honest to say it.
    private func giveTheSoundBack() {
        Task {
            for attempt in 0..<Self.giveBackAttempts {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.giveBackRetry)
                }
                if AudioFocus.giveBack() {
                    return
                }
            }
        }
    }

    // MARK: - CXProviderDelegate

    // The provider calls these on the main queue, which `setDelegate(_:queue: nil)` asks for.

    /// iOS reset CallKit, which ends every call it had. The next call makes a new provider,
    /// and a call that had no sound from it yet goes on without it.
    nonisolated func providerDidReset(_ provider: CXProvider) {
        let reset = ObjectIdentifier(provider)
        MainActor.assumeIsolated {
            if let current = Self.provider, ObjectIdentifier(current) == reset {
                Self.provider = nil
                current.invalidate()
            }
            guard isStarted, !isEnded else {
                return
            }
            follow(placement.handle(.reset))
        }
    }

    /// iOS has the call: its sound is set up now, and iOS makes it active after. Only plain
    /// values cross onto the main actor; the action and the provider are answered here.
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let callID = action.callUUID
        let isTaken = MainActor.assumeIsolated { () -> Bool in
            // A start iOS delivers after a reset moved the call into the app is not taken.
            guard callID == id, !isEnded, placement.isThroughCallKit else {
                return false
            }
            do {
                try AudioFocus.takeForCall(activating: false)
            } catch {
                AudioFocus.callEnded()
                AudioFocus.rest()
                couldNotHaveTheSound()
                return false
            }
            isSoundTaken = true
            return true
        }
        guard isTaken else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: callID, startedConnectingAt: Date())
        action.fulfill()
    }

    /// The red button on the Lock Screen, the Dynamic Island, AirPods, the car, or the
    /// call's own screen through `end()`.
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            ended()
        }
        action.fulfill(withDateEnded: Date())
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let isMuted = action.isMuted
        MainActor.assumeIsolated {
            self.isMuted = isMuted
            onMuted?(isMuted)
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        let isOnHold = action.isOnHold
        MainActor.assumeIsolated {
            onHeld?(isOnHold)
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            _ = placement.handle(.soundActive)
            isAudioActive = true
            onAudio?(true)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            isAudioActive = false
            if isEnded {
                AudioFocus.rest()
            } else {
                onAudio?(false)
            }
        }
    }
}
