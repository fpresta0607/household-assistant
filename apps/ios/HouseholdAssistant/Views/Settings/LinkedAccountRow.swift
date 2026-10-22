// One account a connector is signed in with, on the connector's page: the provider's icon,
// the provider's name for the account, its address and when it was linked, a line when its
// sign-in no longer works, what the assistant can do with it, then Switch account and
// Disconnect. Both are glass: royal is only Switch account's rim and words, and Disconnect
// is the system's red words, never a fill. A sign-in set up on the assistant's computer has
// neither, since the gateway would refuse both, and says where it changes instead.

import SwiftUI

struct LinkedAccountRow: View {
    let account: LinkedAccount
    /// The connector's icon, its provider's.
    let icon: String
    let provider: String
    let assistant: String
    /// While a sign-in or sign-out of its connector is on its way to the gateway.
    let isBusy: Bool
    let switchAccount: () -> Void
    let disconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrandTile(icon, fallbackName: provider, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.body)
                        .foregroundStyle(Palette.text)
                    if let email = account.email, email != account.name {
                        Text(email)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    if let linked = account.linkedDate {
                        Text("Linked \(linked.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let status = account.statusWords {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.text)
            }
            if !account.abilities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(account.abilities, id: \.self) { ability in
                        AssistantAbility(text: ability)
                    }
                }
            }
            if account.canDisconnect {
                actions
            } else {
                Text("Set up on \(assistant)'s computer, so it changes only there.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(account.switchWords, action: switchAccount)
                    .font(.footnote.weight(.bold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .foregroundStyle(Palette.highlight)
                    .overlay {
                        Capsule()
                            .strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("\(account.switchWords), \(account.email ?? account.name)")
                Button("Disconnect", role: .destructive, action: disconnect)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityLabel("Disconnect \(account.email ?? account.name)")
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }
}
