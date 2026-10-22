// Account's iPhones: each one paired to this person's gateway, this one first with whether
// it reaches the gateway now, and Remove on the others, which asks Account for a yes.
// Until the gateway has listed them, this iPhone alone.

import SwiftUI
import UIKit

struct PairedPhonesSection: View {
    @Environment(AppModel.self) private var model
    /// The phone whose removal waits for a yes on Account.
    @Binding var removing: PairedPhone?

    var body: some View {
        let phones = model.pairedPhones
        SettingsGroup("Your iPhones", refusal: phones.refusal) {
            if phones.phones.isEmpty {
                SettingsRow("This iPhone", subtitle: UIDevice.current.model) {
                    SymbolTile("iphone", color: Color(white: 0.56))
                } trailing: {
                    connectionState
                }
            }
            ForEach(phones.phones) { phone in
                if phone.isThisPhone {
                    SettingsRow("This iPhone", subtitle: thisPhoneSubtitle(phone)) {
                        SymbolTile(phone.symbol, color: Color(white: 0.56))
                    } trailing: {
                        connectionState
                    }
                } else {
                    SettingsRow(phone.name, subtitle: Self.subtitle(of: phone)) {
                        SymbolTile(phone.symbol, color: Color(white: 0.56))
                    } trailing: {
                        if phones.isRemoving(phone) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Remove", role: .destructive) {
                                removing = phone
                            }
                            .font(.callout)
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(phone.name)")
                        }
                    }
                }
            }
        }
    }

    /// The green dot while this iPhone reaches the gateway, and the plain words while it
    /// does not, since only connected things are a dot (CFO notes section 13).
    @ViewBuilder
    private var connectionState: some View {
        if model.connection.state == .connected {
            StatusDot()
        } else {
            Text("Not connected")
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private func thisPhoneSubtitle(_ phone: PairedPhone) -> String {
        model.connection.state == .connected ? "\(phone.modelName), now" : Self.subtitle(of: phone)
    }

    /// Its model, and when the gateway last saw it, as "iPad, last seen yesterday".
    static func subtitle(of phone: PairedPhone) -> String {
        guard let seen = phone.lastSeen else {
            return phone.modelName
        }
        return "\(phone.modelName), last seen \(seen.formatted(.relative(presentation: .named)))"
    }
}
