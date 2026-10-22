// The things this app remembers that are not secrets, among them every choice in
// Appearance and Accessibility, which stay on this phone and never reach a gateway.

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings: LocationSharingStore, LiveShareStore, PlaceWatchStore, TodaySeenStore, SpendStore {
    /// The gateway's address, from the setup code that paired this phone.
    var gatewayHost: String {
        didSet {
            defaults.set(gatewayHost, forKey: "gateway-host")
        }
    }

    /// Whether the first run has offered notifications, voice and location, after
    /// pairing. Until it has, those steps show instead of Chats.
    var hasOfferedPermissions: Bool {
        didSet {
            defaults.set(hasOfferedPermissions, forKey: "permissions-offered")
        }
    }

    /// Whether this phone's person linked their Apple ID to the gateway it is paired
    /// with, so a new iPhone can join as them by signing in with Apple.
    var hasLinkedAppleID: Bool {
        didSet {
            defaults.set(hasLinkedAppleID, forKey: "linked-apple-id")
        }
    }

    /// Whether this phone shares where it is, with whom and until when. Nil while off,
    /// which is where it starts.
    var locationSharing: LocationSharing? {
        didSet {
            defaults.set(locationSharing.flatMap { try? JSONEncoder().encode($0) }, forKey: "location-sharing")
        }
    }

    var isLocationHeldByGateway: Bool {
        didSet {
            defaults.set(isLocationHeldByGateway, forKey: "location-held")
        }
    }

    /// Precise Location, the app's own switch, on as iOS's own starts.
    var isLocationPrecise: Bool {
        didSet {
            defaults.set(isLocationPrecise, forKey: "location-precise")
        }
    }

    /// The live maps this phone shared and still moves.
    var liveShares: [LiveShare] {
        didSet {
            defaults.set(try? JSONEncoder().encode(liveShares), forKey: "live-shares")
        }
    }

    /// The places this phone watches for reminders by place, which stay on this phone.
    var placeWatches: [PlaceWatch] {
        didSet {
            defaults.set(try? JSONEncoder().encode(placeWatches), forKey: "place-watches")
        }
    }

    /// The household's month as the gateway last answered it, for the Spend page to open on.
    var spendReport: SpendReport? {
        didSet {
            defaults.set(spendReport.flatMap { try? JSONEncoder().encode($0) }, forKey: "spend-report")
        }
    }

    var firedPlaceWatches: [String] {
        didSet {
            defaults.set(firedPlaceWatches, forKey: "place-watches-fired")
        }
    }

    /// When the whole Today card on Chats was last seen or checked off.
    var todaySeenAt: Date? {
        didSet {
            defaults.set(todaySeenAt, forKey: "today-seen-at")
        }
    }

    var todaySeenVerseDay: String? {
        didSet {
            defaults.set(todaySeenVerseDay, forKey: "today-seen-verse-day")
        }
    }

    // MARK: Appearance

    var appearance: AppearanceChoice {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }

    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            applyTheme()
        }
    }

    /// The ring round each assistant's face, by participant id, once its person picked one
    /// with Edit Color on the assistant's page. Every ring of that assistant's face, the
    /// widgets' included, reads this one value. Gold until then.
    var assistantRings: [String: RingColor] {
        didSet {
            defaults.set(try? JSONEncoder().encode(assistantRings), forKey: "assistant-rings")
        }
    }

    // MARK: Accessibility

    var reduceMotion: ReduceMotionChoice {
        didSet {
            defaults.set(reduceMotion.rawValue, forKey: "reduce-motion")
        }
    }

    var textSize: TextSizeChoice {
        didSet {
            defaults.set(textSize.rawValue, forKey: "text-size")
        }
    }

    var isTextBold: Bool {
        didSet {
            defaults.set(isTextBold, forKey: "bold-text")
        }
    }

    var isHapticsOn: Bool {
        didSet {
            defaults.set(isHapticsOn, forKey: "haptics")
        }
    }

    /// Whether a voice note shows its words under it.
    var shouldShowTranscripts: Bool {
        didSet {
            defaults.set(shouldShowTranscripts, forKey: "transcripts")
        }
    }

    /// Whether Talk says the assistant's replies aloud, or only shows them.
    var shouldReadRepliesAloud: Bool {
        didSet {
            defaults.set(shouldReadRepliesAloud, forKey: "read-aloud")
        }
    }

    // MARK: Privacy

    /// App Lock's Require Face ID: whether Steward AI opens only for Face ID or this
    /// iPhone's passcode. Off until its person turns it on.
    var isAppLockOn: Bool {
        didSet {
            defaults.set(isAppLockOn, forKey: "app-lock")
        }
    }

    /// When App Lock asks again once the app has been in the background.
    var appLockTiming: AppLockTiming {
        didSet {
            defaults.set(appLockTiming.rawValue, forKey: "app-lock-timing")
        }
    }

    /// The Contacts connector's switch: whether a text the assistant drafts may look in
    /// Contacts for who it is for. Off, no card looks, and its person chooses who. Kept under
    /// its own key since it became a connector, so it starts off on every phone, even one
    /// whose older Privacy switch was on.
    var shouldLookInContacts: Bool {
        didSet {
            defaults.set(shouldLookInContacts, forKey: "contacts-connector")
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The demo keeps its settings apart from a real pairing's.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gatewayHost = defaults.string(forKey: "gateway-host") ?? ""
        hasOfferedPermissions = defaults.bool(forKey: "permissions-offered")
        hasLinkedAppleID = defaults.bool(forKey: "linked-apple-id")
        locationSharing = defaults.data(forKey: "location-sharing").flatMap { try? JSONDecoder().decode(LocationSharing.self, from: $0) }
        isLocationHeldByGateway = defaults.bool(forKey: "location-held")
        isLocationPrecise = defaults.object(forKey: "location-precise") as? Bool ?? true
        liveShares = defaults.data(forKey: "live-shares").flatMap { try? JSONDecoder().decode([LiveShare].self, from: $0) } ?? []
        placeWatches = defaults.data(forKey: "place-watches").flatMap { try? JSONDecoder().decode([PlaceWatch].self, from: $0) } ?? []
        firedPlaceWatches = defaults.stringArray(forKey: "place-watches-fired") ?? []
        todaySeenAt = defaults.object(forKey: "today-seen-at") as? Date
        todaySeenVerseDay = defaults.string(forKey: "today-seen-verse-day")
        spendReport = defaults.data(forKey: "spend-report").flatMap { try? JSONDecoder().decode(SpendReport.self, from: $0) }
        let savedAppearance = defaults.string(forKey: "appearance").flatMap(AppearanceChoice.init(rawValue:)) ?? .automatic
        appearance = savedAppearance
        let savedTheme = AppTheme.restored(theme: defaults.string(forKey: "theme"),
            light: defaults.string(forKey: "theme-light"), dark: defaults.string(forKey: "theme-dark"), prefersDark: savedAppearance == .dark)
        theme = savedTheme
        defaults.set(savedTheme.rawValue, forKey: "theme")
        defaults.removeObject(forKey: "theme-light")
        defaults.removeObject(forKey: "theme-dark")
        assistantRings = defaults.data(forKey: "assistant-rings").flatMap { try? JSONDecoder().decode([String: RingColor].self, from: $0) } ?? [:]
        // Retire only the old appearance overrides; unrelated settings and face rings stay.
        for key in ["appearance-custom", "appearance-materials", "accent", "rainbow", "rainbow-dark", "rim-palette",
                    "glass-tint", "chat-background", "chat-photo", "accent-color", "bubble-color", "other-bubble-color"] {
            defaults.removeObject(forKey: key)
        }
        reduceMotion = defaults.string(forKey: "reduce-motion").flatMap(ReduceMotionChoice.init(rawValue:)) ?? .likeIPhone
        textSize = defaults.string(forKey: "text-size").flatMap(TextSizeChoice.init(rawValue:)) ?? .likeIPhone
        isTextBold = defaults.bool(forKey: "bold-text")
        isHapticsOn = defaults.object(forKey: "haptics") as? Bool ?? true
        shouldShowTranscripts = defaults.object(forKey: "transcripts") as? Bool ?? true
        shouldReadRepliesAloud = defaults.object(forKey: "read-aloud") as? Bool ?? true
        isAppLockOn = defaults.bool(forKey: "app-lock")
        appLockTiming = defaults.string(forKey: "app-lock-timing").flatMap(AppLockTiming.init(rawValue:)) ?? .immediately
        shouldLookInContacts = defaults.bool(forKey: "contacts-connector")
        applyTheme()
    }

    func revertAppearance() {
        appearance = .automatic
        theme = .default
    }

    private func applyTheme() {
        ThemeSelection.shared.theme = theme
    }
}
