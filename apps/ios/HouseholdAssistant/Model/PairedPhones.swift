// The iPhones this phone's person has paired to their own gateway, for Account: this
// iPhone first, removing another, and a setup code for a new one.
//
// Removing a phone and asking for a code are each signed with this phone's device key,
// as a settings change is, and the gateway takes them only from its own person's phones.
// The list a removal answers with is what the gateway has left, so it is what shows. A
// setup code works once, for ten minutes, so it is kept only while its page is open, and
// a code already shown is never shown again.

import Foundation
import Observation

@MainActor
@Observable
final class PairedPhones {
    /// This iPhone first, then the others in the gateway's order.
    private(set) var phones: [PairedPhone] = []
    /// Why the last removal did not go through, in the gateway's words. The next clears it.
    private(set) var refusal: String?
    private(set) var newPhoneCode: NewPhoneCode?
    private(set) var isAskingForCode = false
    /// Why the gateway gave no code, in its words.
    private(set) var codeRefusal: String?
    /// The phones whose removal is on its way, by device id.
    private var removing: Set<String> = []

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let sign: (String) throws -> String
    @ObservationIgnored private let now: () -> Date
    /// When the newest action was signed: the gateway takes only a newer one.
    @ObservationIgnored private var lastActionAt = 0

    init(connection: GatewayConnection, sign: @escaping (String) throws -> String, now: @escaping () -> Date = Date.init) {
        self.connection = connection
        self.sign = sign
        self.now = now
    }

    /// Keeps the last list when the gateway cannot be asked.
    func refresh() async {
        if let list = try? await connection.pairedPhones() {
            phones = Self.thisPhoneFirst(list)
        }
    }

    func isRemoving(_ phone: PairedPhone) -> Bool {
        removing.contains(phone.id)
    }

    func remove(_ phone: PairedPhone) async {
        refusal = nil
        removing.insert(phone.id)
        let action = PhoneAction(at: nextActionAt(), kind: .remove(device: phone.id))
        do {
            let signature = try sign(action.signedText)
            phones = Self.thisPhoneFirst(try await connection.removePhone(action, signature: signature))
        } catch {
            refusal = ErrorText.describe(error)
        }
        removing.remove(phone.id)
    }

    /// A fresh code for a new iPhone, in place of any shown before.
    func askForCode() async {
        newPhoneCode = nil
        codeRefusal = nil
        isAskingForCode = true
        let action = PhoneAction(at: nextActionAt(), kind: .pair)
        do {
            let signature = try sign(action.signedText)
            newPhoneCode = try await connection.newPhoneCode(action, signature: signature)
        } catch {
            codeRefusal = ErrorText.describe(error)
        }
        isAskingForCode = false
    }

    /// Its page closed: the code is not shown again.
    func forgetCode() {
        newPhoneCode = nil
        codeRefusal = nil
    }

    /// Pairing with another gateway, or again: a different person's phones never carry over.
    func reset() {
        phones = []
        refusal = nil
        removing = []
        forgetCode()
    }

    private static func thisPhoneFirst(_ list: [PairedPhone]) -> [PairedPhone] {
        list.filter(\.isThisPhone) + list.filter { !$0.isThisPhone }
    }

    /// Now, or a millisecond after the last action if the clock has not moved on since.
    private func nextActionAt() -> Int {
        lastActionAt = max(Int((now().timeIntervalSince1970 * 1000).rounded()), lastActionAt + 1)
        return lastActionAt
    }
}
