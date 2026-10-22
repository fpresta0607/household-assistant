// Where a call's sound goes, and what takes it away: it applies the call's routing
// (CallRouting), the speaker from the start, the earpiece at the ear or when the person
// chooses it, and AirPods, a headset or the car while one is connected, and it watches for
// interruptions.
//
// The speaker overrides where iOS sends the sound. The earpiece picks the iPhone's own
// microphone, which brings the sound with it, as Telegram does, and something connected
// is left to iOS, which sends a call to it. iOS says whenever the route moves, a headset
// going in or out or the car connecting, and what is connected is read again then. The
// sound is set only when the routing's answer changes, so a route the person moves in
// Control Center is not fought over. The microphone itself starts again on each new route
// (SpeechListener).
//
// While nothing is connected the proximity sensor is watched: iOS turns the screen off at
// the ear, and the sound moves to the earpiece and back as the phone is raised and
// lowered. While something is connected the phone is not at the ear, and the call's
// screen keeps it awake instead (CallView).
//
// Siri, an alarm or another app can take the sound for a moment. The call goes on hold
// then (CallState), and once iOS says that is over the sound is made the call's again and
// the call comes off hold. Should the sound not come back, the call stays on hold until it
// is ended, or until iOS hands the sound back through CallKit.

import AVFoundation
import Observation
import UIKit

@MainActor
@Observable
final class CallAudio {
    /// Where the sound goes, and what the Speaker button shows.
    private(set) var routing = CallRouting()
    /// Another sound took the call's (true), or gave it back and the call has it again (false).
    @ObservationIgnored var onInterruption: ((Bool) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isFollowing = false
    /// What the sound was last set to, so it is set again only when the answer changes.
    @ObservationIgnored private var applied: CallRouting.Output?

    /// Follows the routes, the ear and the interruptions until `stop()`.
    func start() {
        guard !isFollowing else {
            return
        }
        isFollowing = true
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // All asked for on the main queue.
        observers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.readRoutes()
                }
            },
            center.addObserver(forName: UIDevice.proximityStateDidChangeNotification, object: UIDevice.current, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.apply()
                }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
                guard
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: raw)
                else {
                    return
                }
                let hasBegun = type == .began
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.interrupted(hasBegun)
                }
            },
        ]
        readRoutes()
    }

    func stop() {
        isFollowing = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    /// The Speaker button: the speaker, or the earpiece. Nothing while something is connected.
    func toggleSpeaker() {
        guard routing.canToggle else {
            return
        }
        routing.isEarpieceChosen.toggle()
        apply()
    }

    /// iOS made the call's sound active: the route is set on it afresh, since one set before
    /// it was active does not hold.
    func soundBecameActive() {
        applied = nil
        readRoutes()
    }

    private func readRoutes() {
        let session = AVAudioSession.sharedInstance()
        let routes = CallAudioRoutes(
            inputs: (session.availableInputs ?? []).map { Self.port($0) },
            outputs: session.currentRoute.outputs.map { Self.port($0) },
            hasReceiver: UIDevice.current.userInterfaceIdiom == .phone
        )
        routing.device = routes.device
        apply()
    }

    /// Sets the sound where the routing says, when that has changed. One iOS refuses is
    /// tried again at the next change.
    private func apply() {
        let isWatched = isFollowing && routing.isProximityWatched
        UIDevice.current.isProximityMonitoringEnabled = isWatched
        // Read here as well as when it changes, so a call started at the ear starts there.
        routing.isNearEar = isWatched && UIDevice.current.proximityState
        let output = routing.output
        guard output != applied else {
            return
        }
        let session = AVAudioSession.sharedInstance()
        let phoneMicrophone = session.availableInputs?.first { $0.portType == .builtInMic }
        do {
            switch output {
            case .speaker:
                try session.setPreferredInput(phoneMicrophone)
                try session.overrideOutputAudioPort(.speaker)
            case .earpiece:
                try session.overrideOutputAudioPort(.none)
                try session.setPreferredInput(phoneMicrophone)
            case .external:
                // iOS sends a call to whatever is connected, unless told otherwise.
                try session.overrideOutputAudioPort(.none)
                try session.setPreferredInput(nil)
            }
            applied = output
        } catch {
            applied = nil
        }
    }

    /// An interruption that ends gives the sound back to the call: it is made active again,
    /// and the call is told only once it is.
    private func interrupted(_ hasBegun: Bool) {
        guard isFollowing else {
            return
        }
        if hasBegun {
            onInterruption?(true)
        } else if (try? AVAudioSession.sharedInstance().setActive(true)) != nil {
            soundBecameActive()
            onInterruption?(false)
        }
    }

    private nonisolated static func port(_ description: AVAudioSessionPortDescription) -> CallAudioRoutes.Port {
        CallAudioRoutes.Port(id: description.uid, name: description.portName, kind: kind(of: description.portType))
    }

    private nonisolated static func kind(of type: AVAudioSession.Port) -> CallAudioRoutes.Kind {
        switch type {
        case .builtInMic:
            return .phoneMicrophone
        case .builtInReceiver:
            return .receiver
        case .builtInSpeaker:
            return .speaker
        case .headphones, .headsetMic, .usbAudio, .lineIn, .lineOut:
            return .wired
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return .bluetooth
        case .carAudio:
            return .car
        default:
            return .other
        }
    }
}
