// What this phone lets Steward AI use: asked once, one step each, right after
// pairing, and shown in Settings from then on. Reading where each stands asks
// nothing; only `request` puts iOS's question on screen. The rest iOS asks about the
// first time it is used, Contacts (when its connector is turned on), adding to Photos, the
// camera and Face ID, and Bold Text is the iPhone's own: each is read here too, so every
// Settings row that mirrors one says what the iPhone says, again each time the app comes
// back.

import AVFoundation
import Contacts
import CoreLocation
import LocalAuthentication
import Observation
import Photos
import Speech
import UIKit
import UserNotifications

@MainActor
@Observable
final class Permissions: NSObject, CLLocationManagerDelegate {
    /// Read from iOS. The screenshot tests, with no iOS to read, set it themselves.
    var statuses: [PermissionKind: PermissionStatus] = [:]
    /// Whether iOS lets the app hear it moved while closed, which sharing for an hour,
    /// tonight or always needs. Only While Using shares only while the app is open.
    private(set) var isLocationAlways = false
    /// Precise Location, the person's own switch in iOS: off, iOS gives only the area.
    /// Steward AI's own switch (LocationSharingModel.isPrecise) can ask for it.
    private(set) var isLocationPrecise = false
    /// Contacts, adding to Photos, the camera and Face ID as iOS has them. The screenshot
    /// tests set it themselves.
    var phoneAccess: [PhoneAccess: PhoneAccessState] = [:]
    /// What App Lock opens with on this iPhone: Face ID, Touch ID, Optic ID, or with none,
    /// the passcode.
    var lockName = "Face ID"
    /// Whether iOS delivers Steward AI's notifications quietly, to Notification Center only.
    var isDeliveredQuietly = false
    /// Bold Text in the iPhone's own Settings, which bolds the app whatever its own switch says.
    var isTextBoldOnIPhone = false

    /// Off in the screenshot tests and the demo, which have nobody to answer iOS:
    /// the steps still show, and nothing is read or asked.
    @ObservationIgnored let isAllowedToAsk: Bool
    /// Contacts alone, which the demo may read and ask for when a UI test answers iOS with
    /// the Simulator's sample contacts (DemoContacts).
    @ObservationIgnored let isAllowedToAskForContacts: Bool
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var locationAnswer: CheckedContinuation<Void, Never>?

    init(isAllowedToAsk: Bool, isAllowedToAskForContacts: Bool) {
        self.isAllowedToAsk = isAllowedToAsk
        self.isAllowedToAskForContacts = isAllowedToAskForContacts
        super.init()
        locationManager.delegate = self
    }

    func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notAsked
    }

    func state(of kind: PhoneAccess) -> PhoneAccessState {
        phoneAccess[kind] ?? .notAsked
    }

    /// Reads what iOS has recorded for each, and keeps this phone's address for
    /// notifications fresh once they are on.
    func refresh() async {
        readContacts()
        guard isAllowedToAsk else {
            return
        }
        let delivery = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let notifications = Self.status(of: delivery)
        isDeliveredQuietly = delivery == .provisional
        statuses[.notifications] = notifications
        statuses[.voice] = PermissionStatus.combined([
            Self.status(of: AVAudioApplication.shared.recordPermission),
            Self.status(of: SFSpeechRecognizer.authorizationStatus()),
        ])
        readLocation()
        phoneAccess[.photos] = Self.state(of: PHPhotoLibrary.authorizationStatus(for: .addOnly))
        phoneAccess[.camera] = Self.state(of: AVCaptureDevice.authorizationStatus(for: .video))
        readLock()
        isTextBoldOnIPhone = UIAccessibility.isBoldTextEnabled
        if notifications == .allowed {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Location as iOS has it now: on every refresh, and the moment iOS says it changed, so
    /// the Location row in Settings, which refreshes nothing, says what Account and Location
    /// say.
    private func readLocation() {
        let location: PermissionStatus
        switch locationManager.authorizationStatus {
        case .notDetermined:
            location = .notAsked
        case .authorizedWhenInUse, .authorizedAlways:
            location = .allowed
        case .denied, .restricted:
            location = .denied
        @unknown default:
            location = .denied
        }
        statuses[.location] = location
        isLocationAlways = locationManager.authorizationStatus == .authorizedAlways
        isLocationPrecise = locationManager.accuracyAuthorization == .fullAccuracy
    }

    /// What App Lock can open with here, and whether iOS lets Steward AI use it.
    private func readLock() {
        let context = LAContext()
        var biometrics: NSError?
        let canUseBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometrics)
        var owner: NSError?
        let hasPasscode = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &owner)
            || (owner as? LAError)?.code != .passcodeNotSet
        let biometricsError = canUseBiometrics ? nil : (biometrics as? LAError)?.code
        phoneAccess[.faceID] = Self.lockState(biometryType: context.biometryType, biometricsError: biometricsError, hasPasscode: hasPasscode)
        lockName = Self.lockName(of: context.biometryType, biometricsError: biometricsError)
    }

    /// Notifications iOS delivers quietly, to Notification Center only, are still on.
    static func status(of notifications: UNAuthorizationStatus) -> PermissionStatus {
        switch notifications {
        case .notDetermined:
            return .notAsked
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func status(of microphone: AVAudioApplication.recordPermission) -> PermissionStatus {
        switch microphone {
        case .undetermined:
            return .notAsked
        case .granted:
            return .allowed
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func status(of speech: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch speech {
        case .notDetermined:
            return .notAsked
        case .authorized:
            return .allowed
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func state(of contacts: CNAuthorizationStatus) -> PhoneAccessState {
        switch contacts {
        case .notDetermined:
            return .notAsked
        case .authorized:
            return .allowed
        case .limited:
            return .limited
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func state(of photos: PHAuthorizationStatus) -> PhoneAccessState {
        switch photos {
        case .notDetermined:
            return .notAsked
        case .authorized:
            return .allowed
        case .limited:
            return .limited
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func state(of camera: AVAuthorizationStatus) -> PhoneAccessState {
        switch camera {
        case .notDetermined:
            return .notAsked
        case .authorized:
            return .allowed
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Whether App Lock can open with the iPhone's Face ID, Touch ID or Optic ID: on when
    /// iOS lets Steward AI use it, or when this iPhone has none set up and the passcode
    /// opens it instead; off when the person said no to it for Steward AI, and App Lock
    /// asks for the passcode; not set up with no passcode, when it has nothing to ask for.
    static func lockState(biometryType: LABiometryType, biometricsError: LAError.Code?, hasPasscode: Bool) -> PhoneAccessState {
        guard hasPasscode else {
            return .unavailable
        }
        guard biometryType != .none, let biometricsError else {
            return .allowed
        }
        switch biometricsError {
        case .biometryNotEnrolled, .biometryLockout:
            return .allowed
        default:
            return .denied
        }
    }

    /// What App Lock asks for: the passcode on an iPhone with no face or finger set up.
    static func lockName(of biometryType: LABiometryType, biometricsError: LAError.Code?) -> String {
        if biometricsError == .biometryNotEnrolled {
            return "Passcode"
        }
        switch biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        default:
            return "Passcode"
        }
    }

    /// Puts iOS's own question on screen, then reads the answer.
    func request(_ kind: PermissionKind) async {
        guard isAllowedToAsk else {
            return
        }
        switch kind {
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .voice:
            _ = await AVAudioApplication.requestRecordPermission()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        case .location:
            // While Using only: Always is asked at the moment something must go on with
            // the app closed (LocationAlwaysAsk).
            if locationManager.authorizationStatus == .notDetermined {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    locationAnswer = continuation
                    locationManager.requestWhenInUseAuthorization()
                }
            }
        }
        await refresh()
    }

    /// Asked when the person turns on the Contacts connector: iOS's own question the one
    /// time it has never asked, everyone or only the people chosen, then the answer read.
    func requestContacts() async {
        guard isAllowedToAskForContacts else {
            return
        }
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        readContacts()
    }

    /// Contacts as iOS has them, read without asking.
    func readContacts() {
        guard isAllowedToAskForContacts else {
            return
        }
        phoneAccess[.contacts] = Self.state(of: CNContactStore.authorizationStatus(for: .contacts))
    }

    /// Asked when the person turns on something that must go on with the app closed
    /// (LocationAlwaysAsk): iOS's own question, with the Always usage string, the first
    /// time; once While Using is allowed, iOS's offer to keep it on in the background.
    func requestAlways() async {
        guard isAllowedToAsk else {
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                locationAnswer = continuation
                locationManager.requestAlwaysAuthorization()
            }
        case .authorizedWhenInUse:
            // iOS offers Always at most once and says nothing when it will not, so this
            // does not wait for an answer.
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        await refresh()
    }

    /// Steward AI's own Precise Location switch, turned on: when iOS gives the app only the
    /// area, asks iOS for precise with its own question. iOS may keep it approximate, and
    /// then `isLocationPrecise` stays false for the switch to say so. Before iOS has been
    /// asked about location at all there is nothing to ask yet: its first question carries
    /// its own Precise switch.
    func askForPrecise() async {
        guard isAllowedToAsk, status(of: .location) == .allowed, locationManager.accuracyAuthorization == .reducedAccuracy else {
            return
        }
        _ = try? await locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseSharing")
        await refresh()
    }

    /// Called on the main thread, where the manager was made: once when it is made,
    /// before anything was asked, and again when the person answers, here or in iOS
    /// Settings.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if isAllowedToAsk {
                readLocation()
            }
            guard locationManager.authorizationStatus != .notDetermined else {
                return
            }
            locationAnswer?.resume()
            locationAnswer = nil
        }
    }
}
