// Sharing where this phone is with its own assistant, as its person chose: off until they
// turn it on, with their assistant only or the family room too, for an hour, until
// tonight or always, and paused or stopped whenever they like.
//
// The phone tells its own gateway only, and sparingly (LocationSendRule): a position when
// it is news, and "off" when sharing pauses, stops or runs out, so the gateway forgets.
// Every report is signed with this phone's device key, as a message is. Nothing goes to
// Apple or anyone else, and nothing is sent while paused. With Precise Location off, only
// the neighbourhood is sent, whatever iOS measured.

import Foundation
import Observation

@MainActor
@Observable
final class LocationSharingModel {
    /// Why the last report did not reach the gateway, in the gateway's words.
    private(set) var errorText: String?

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let sign: (String) throws -> String
    @ObservationIgnored private let store: LocationSharingStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    /// The newest position iOS gave while sharing was on, sent or not, as iOS measured it.
    @ObservationIgnored private var latest: LocationFix?
    /// The last position the gateway kept since sharing last started or resumed, as sent.
    @ObservationIgnored private var lastSent: LocationFix?
    /// When the newest report was signed: the gateway takes only a newer one.
    @ObservationIgnored private var lastReportAt = 0
    /// Told whenever sharing turns on or off, pauses, resumes or changes, so the phone
    /// watches for moves exactly while it shares.
    @ObservationIgnored var onChange: (() -> Void)?

    init(
        connection: GatewayConnection,
        sign: @escaping (String) throws -> String,
        store: LocationSharingStore,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.connection = connection
        self.sign = sign
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    /// Nil while off.
    var sharing: LocationSharing? {
        store.locationSharing
    }

    /// Whether the phone tells its gateway where it is now.
    var isSending: Bool {
        sharing?.isSending(at: now()) ?? false
    }

    /// Whether the gateway may still have a position from this phone: from the moment one is
    /// sent until a stop reaches it.
    var isHeldByGateway: Bool {
        store.isLocationHeldByGateway
    }

    /// Precise Location, the app's own switch. Off, only the neighbourhood is sent.
    var isPrecise: Bool {
        store.isLocationPrecise
    }

    // MARK: - The person's choices

    func start(with audience: LocationAudience, for span: LocationSpan) async {
        store.locationSharing = LocationSharing(audience: audience, span: span, from: now(), calendar: calendar)
        changed()
        await sendLatest()
    }

    /// With the assistant only, or the family room too. The clock keeps running.
    func share(with audience: LocationAudience) async {
        guard var sharing, sharing.audience != audience else {
            return
        }
        sharing.audience = audience
        store.locationSharing = sharing
        changed()
        await sendLatest()
    }

    /// For how long, starting again from now.
    func share(for span: LocationSpan) async {
        guard let sharing else {
            return
        }
        var restarted = LocationSharing(audience: sharing.audience, span: span, from: now(), calendar: calendar)
        restarted.isPaused = sharing.isPaused
        store.locationSharing = restarted
        changed()
        await sendLatest()
    }

    /// Precise or only the neighbourhood. While sharing, the newest position goes again at
    /// once, as the person now chose.
    func share(precisely isPrecise: Bool) async {
        guard isPrecise != store.isLocationPrecise else {
            return
        }
        store.isLocationPrecise = isPrecise
        guard sharing != nil else {
            return
        }
        changed()
        await sendLatest()
    }

    func pause() async {
        guard var sharing, !sharing.isPaused else {
            return
        }
        sharing.isPaused = true
        store.locationSharing = sharing
        changed()
        await sendStopIfHeld()
    }

    func resume() async {
        await endIfOver()
        guard var sharing, sharing.isPaused else {
            return
        }
        sharing.isPaused = false
        store.locationSharing = sharing
        changed()
        await sendLatest()
    }

    func stop() async {
        latest = nil
        if sharing != nil {
            store.locationSharing = nil
            changed()
        }
        await sendStopIfHeld()
    }

    /// Pairing with another gateway, or again: a share belongs to the gateway it was given
    /// to and never carries over. The link to that one is already going, so nothing is sent,
    /// and it forgets the position at the share's end or when it restarts.
    func reset() {
        latest = nil
        store.locationSharing = nil
        store.isLocationHeldByGateway = false
        changed()
    }

    /// Turns sharing off once its time is up.
    func endIfOver() async {
        if let sharing, sharing.isOver(at: now()) {
            await stop()
        }
    }

    // MARK: - What iOS measured

    /// A position from iOS: sent when sharing is on and it is news.
    func consider(_ fix: LocationFix) async {
        await endIfOver()
        guard sharing != nil else {
            return
        }
        if latest.map({ fix.at > $0.at }) ?? true {
            latest = fix
        }
        let position = told(fix)
        guard isSending, LocationSendRule.shouldSend(position, after: lastSent) else {
            return
        }
        await send(position)
    }

    /// Once the link is back, or the app comes forward: ends a share whose time is up, and
    /// sends whatever did not reach the gateway, the newest position or the stop.
    func catchUp() async {
        await endIfOver()
        if isSending {
            if let latest, told(latest) != lastSent {
                await send(told(latest))
            }
        } else {
            await sendStopIfHeld()
        }
    }

    /// A position as the gateway may hear it: exact, or with Precise Location off only
    /// its neighbourhood.
    private func told(_ fix: LocationFix) -> LocationFix {
        store.isLocationPrecise ? fix : fix.approximated
    }

    // MARK: - Telling the gateway

    private func changed() {
        lastSent = nil
        onChange?()
    }

    /// After a change of who, how long or a resume: the newest position again, under the
    /// new terms. With none yet, a gateway still holding one under the old terms forgets it.
    private func sendLatest() async {
        guard isSending else {
            return
        }
        if let latest {
            await send(told(latest))
        } else {
            await sendStopIfHeld()
        }
    }

    /// `fix` as it may be told, exact or approximate.
    private func send(_ fix: LocationFix) async {
        guard let sharing else {
            return
        }
        let report = LocationReport(
            at: nextReportAt(),
            audience: sharing.audience,
            until: sharing.until.map(Self.milliseconds),
            position: fix.position
        )
        // Held from the moment it leaves: a report whose answer was lost may still have arrived.
        store.isLocationHeldByGateway = true
        if await deliver(report) {
            lastSent = fix
        }
    }

    private func sendStopIfHeld() async {
        guard store.isLocationHeldByGateway else {
            return
        }
        if await deliver(.stop(at: nextReportAt())) {
            store.isLocationHeldByGateway = false
        }
    }

    private func deliver(_ report: LocationReport) async -> Bool {
        do {
            let signature = try sign(report.signedText)
            try await connection.roomLocation(report, signature: signature)
            errorText = nil
            return true
        } catch {
            errorText = ErrorText.describe(error)
            return false
        }
    }

    /// Now, or a millisecond after the last report if the clock has not moved on since.
    private func nextReportAt() -> Int {
        lastReportAt = max(Self.milliseconds(now()), lastReportAt + 1)
        return lastReportAt
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }
}
