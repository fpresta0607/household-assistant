// Account: who this phone belongs to, with their own photo to change as for a contact
// (from Photos or the camera, cut to a circle, and seen by everyone in the family room on
// both iPhones), and whether it can reach its assistant, how its person signs in, their iPhones with Remove on the others, anyone waiting for Franco to
// let them in, a code to pair a new iPhone, what iOS lets Steward AI use, and pairing
// this iPhone again.

import SwiftUI
import UIKit

struct AccountPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingPairAgain = false
    /// The iPhone whose removal waits for a yes.
    @State private var removing: PairedPhone?
    @State private var isShowingNewPhoneCode: Bool

    /// The screenshot tests open it with a removal waiting for its yes, or with a new
    /// iPhone's code showing over it.
    init(removing: PairedPhone? = nil, isShowingNewPhoneCode: Bool = false) {
        _removing = State(initialValue: removing)
        _isShowingNewPhoneCode = State(initialValue: isShowingNewPhoneCode)
    }

    var body: some View {
        let me = model.room.me.flatMap { model.room.participant($0.person) }
        let locationState = model.locationState
        SettingsPage("Account") {
            SettingsGroup {
                SettingsRow(
                    me?.name ?? "This iPhone",
                    subtitle: model.connection.state.line(pairedWith: model.identity.map { _ in model.assistantName }),
                    isConnected: model.connection.state == .connected
                ) {
                    ParticipantAvatar(participant: me, size: 40)
                } trailing: {
                    if let me {
                        FaceChooser(for: me) {
                            Text("Edit Photo")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.highlight)
                        }
                    }
                }
                SettingsRow("Telegram", subtitle: "\(model.assistantName) in your chats and The Fam") {
                    BrandTile("telegram")
                } trailing: {
                    EmptyView()
                }
            }
            LinkAppleIDSection()
            PairedPhonesSection(removing: $removing)
            SignInApprovalsSection()
            SettingsGroup {
                Button {
                    isShowingNewPhoneCode = true
                    Task {
                        await model.pairedPhones.askForCode()
                    }
                } label: {
                    Text("Pair a new iPhone")
                        .font(.body)
                        .foregroundStyle(Palette.highlight)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.settingsRow)
            }
            SettingsGroup(
                "What this iPhone lets Steward AI use",
                note: "iOS decides these, so they change on the app's own page there. Sharing your location is your own choice too, in Location."
            ) {
                ForEach(PermissionKind.allCases) { kind in
                    // Location says whether this iPhone shares where it is, in Location's own
                    // words: iOS allowing location is not the same as sharing it.
                    let isLocation = kind == .location
                    SettingsRow(kind.title, subtitle: isLocation ? locationState.sentence(assistant: model.assistantName) : nil) {
                        SymbolTile(kind.symbol, color: Palette.royal)
                    } trailing: {
                        RowValue(text: isLocation ? locationState.label : notificationsAware(kind), opensPage: false)
                    }
                }
                // What iOS asks about the first time it is used, as iOS has it now.
                ForEach(PhoneAccess.allCases) { access in
                    SettingsRow(access == .faceID ? model.permissions.lockName : access.title) {
                        SymbolTile(access.symbol, color: Palette.royal)
                    } trailing: {
                        RowValue(text: model.permissions.state(of: access).label, opensPage: false)
                    }
                }
                OpenIPhoneSettingsRow()
            }
            SettingsGroup {
                Button(role: .destructive) {
                    isConfirmingPairAgain = true
                } label: {
                    Text("Pair this iPhone again")
                        .font(.body)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.settingsRow)
            }
        }
        .task(id: model.connection.state) {
            await model.permissions.refresh()
            if model.connection.state == .connected {
                await model.signInApprovals.refresh()
                await model.pairedPhones.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from iOS Settings: show what changed there.
            if phase == .active {
                Task {
                    await model.permissions.refresh()
                }
            }
        }
        .confirmationDialog("Pair this phone again?", isPresented: $isConfirmingPairAgain, titleVisibility: .visible) {
            Button("Pair again", role: .destructive) {
                model.forgetPairing()
            }
        } message: {
            Text("You will need a new code from \(model.assistantName) in Telegram, or to sign in with Apple.")
        }
        .confirmationDialog(
            removing.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { isShown in
                if !isShown {
                    removing = nil
                }
            }),
            titleVisibility: .visible,
            presenting: removing
        ) { phone in
            Button("Remove", role: .destructive) {
                Task {
                    await model.pairedPhones.remove(phone)
                }
            }
        } message: { phone in
            Text("\(PairedPhonesSection.subtitle(of: phone)). It stops reaching \(model.assistantName) and getting notifications, and needs a new code to pair again.")
        }
        .sheet(isPresented: $isShowingNewPhoneCode, onDismiss: {
            model.pairedPhones.forgetCode()
        }) {
            NewPhoneCodeSheet()
        }
    }

    /// Where one permission stands, with notifications iOS delivers quietly said as such.
    private func notificationsAware(_ kind: PermissionKind) -> String {
        if kind == .notifications, model.permissions.isDeliveredQuietly {
            return "Quiet"
        }
        return model.permissions.status(of: kind).label
    }
}
