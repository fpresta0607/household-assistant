// Settings, the glass tab bar's second tab, which your own face on Chats also opens: you,
// which opens your account, then your own assistant, then what it costs, what it can reach
// and the model it answers with, then where this iPhone is, notifications, privacy,
// appearance and accessibility, each a page of its own. Everything is changed from here,
// never the box.
//
// Each person controls only their own assistant: a change goes to this phone's own
// gateway, signed with this phone's key, and the row shows what the gateway read back.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.assistantSettings
        NavigationStack {
            SettingsPage("Settings") {
                SettingsGroup {
                    NavigationLink {
                        AccountPage()
                    } label: {
                        profile
                    }
                    .buttonStyle(.settingsRow)
                }
                SettingsGroup("Your assistant") {
                    NavigationLink {
                        AssistantPage()
                    } label: {
                        SettingsRow(model.assistantName, subtitle: assistantLine) {
                            AssistantAvatar(emoji: model.identity?.emoji, photo: model.assistantPhoto, size: 34, ring: model.assistantRing)
                        } trailing: {
                            RowValue()
                        }
                    }
                    .buttonStyle(.settingsRow)
                }
                SettingsGroup {
                    NavigationLink {
                        SpendPage()
                    } label: {
                        SettingsRow("Spend") {
                            SymbolTile("chart.bar", color: Color(red: 0x2F / 255, green: 0xB3 / 255, blue: 0x6B / 255))
                        } trailing: {
                            RowValue(text: settings.spend.map { Dollars.amount($0.total) })
                        }
                    }
                    .buttonStyle(.settingsRow)
                    NavigationLink {
                        ConnectorsPage()
                    } label: {
                        SettingsRow("Connectors") {
                            SymbolTile("puzzlepiece.extension", color: Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255))
                        } trailing: {
                            RowValue(text: settings.current.map { _ in "\(model.connectorsOn) on" })
                        }
                    }
                    .buttonStyle(.settingsRow)
                    NavigationLink {
                        ModelPage()
                    } label: {
                        SettingsRow("Models") {
                            BrandTile("openrouter")
                        } trailing: {
                            RowValue(text: settings.current?.model.name, isPending: settings.isPending(.model))
                        }
                    }
                    .buttonStyle(.settingsRow)
                }
                SettingsGroup(note: "Steward AI \(version)") {
                    NavigationLink {
                        LocationSettingsView()
                    } label: {
                        SettingsRow("Location") {
                            SymbolTile("location", color: Color(red: 0x14 / 255, green: 0xA3 / 255, blue: 0xB8 / 255))
                        } trailing: {
                            RowValue(text: model.locationState.label)
                        }
                    }
                    .buttonStyle(.settingsRow)
                    NavigationLink {
                        NotificationsPage()
                    } label: {
                        SettingsRow("Notifications") {
                            SymbolTile("bell", color: Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255))
                        } trailing: {
                            RowValue()
                        }
                    }
                    .buttonStyle(.settingsRow)
                    NavigationLink {
                        PrivacyPage()
                    } label: {
                        SettingsRow("Privacy") {
                            SymbolTile("hand.raised", color: Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255))
                        } trailing: {
                            RowValue()
                        }
                    }
                    .buttonStyle(.settingsRow)
                    NavigationLink {
                        AppearancePage()
                    } label: {
                        SettingsRow("Appearance") {
                            SymbolTile("paintbrush", color: Palette.royal)
                        } trailing: {
                            RowValue()
                        }
                    }
                    .buttonStyle(.settingsRow)
                    NavigationLink {
                        AccessibilityPage()
                    } label: {
                        SettingsRow("Accessibility") {
                            SymbolTile("accessibility", color: Color(red: 0x1C / 255, green: 0x7C / 255, blue: 0xF4 / 255))
                        } trailing: {
                            RowValue()
                        }
                    }
                    .buttonStyle(.settingsRow)
                }
            }
            .task(id: model.connection.state) {
                if model.connection.state == .connected {
                    await settings.load()
                    await settings.loadSpend()
                    await model.signInApprovals.refresh()
                }
            }
        }
    }

    /// This phone's person, whom it is paired with, whether it can reach them, and how many
    /// iPhones wait for them to let them in. It is the only way into Account, where they let
    /// them in, so it carries that count.
    private var profile: some View {
        let me = model.room.me.flatMap { model.room.participant($0.person) }
        return SettingsRow(
            me?.name ?? "This iPhone",
            subtitle: model.connection.state.line(pairedWith: model.identity.map { _ in model.assistantName }),
            isConnected: model.connection.state == .connected
        ) {
            ParticipantAvatar(participant: me, size: 48)
        } trailing: {
            RowValue(text: waitingLine)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Will's voice, GLM 5.3 Flash", once the gateway has said.
    private var assistantLine: String? {
        let settings = model.assistantSettings
        guard let voice = settings.voice, let current = settings.current else {
            return nil
        }
        return "\(voice.name)'s voice, \(current.model.name)"
    }

    /// How many iPhones wait for Franco to let them in. Nil on anybody else's phone.
    private var waitingLine: String? {
        let waiting = model.signInApprovals.waiting.count
        return waiting > 0 ? "\(waiting) waiting" : nil
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
