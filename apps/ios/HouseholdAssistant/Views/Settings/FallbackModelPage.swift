// The second or third text model of this phone's assistant, picked from OpenRouter's live
// list like the first: the one picked now, None to clear it, then the popular ones and a
// search over all of them, each with its company's icon and its price per million tokens.
// The gateway tries them in order when the one before fails or is busy, and a model that
// is already in the chain somewhere else is not offered. The check moves once the gateway
// has made the change.

import SwiftUI

struct FallbackModelPage: View {
    /// 1 for the second model, 2 for the third.
    let position: Int

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var query = ""

    var body: some View {
        let settings = model.assistantSettings
        let name = model.assistantName
        let field = SettingsField.fallbackModel(position)
        let picked = settings.fallbackID(position)
        let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        SettingsPage(position == 1 ? "Second model" : "Third model") {
            if !isSearching {
                SettingsGroup(
                    "Picked",
                    note: position == 1
                        ? "\(name) answers with this one when the first fails or is busy."
                        : "\(name) answers with this one when the first and the second both fail.",
                    refusal: settings.refusal(for: [field])
                ) {
                    if let picked {
                        let listed = settings.models.first { $0.id == picked }
                        SettingsRow(listed?.name ?? picked, subtitle: ModelPrices.line(listed, company: listed?.company ?? "", perMillion: true)) {
                            BrandTile(listed?.icon ?? "symbol:cpu", fallbackName: listed?.company ?? "")
                        } trailing: {
                            checkmark
                        }
                    }
                    none(isPicked: picked == nil)
                }
            }
            // The one picked is in Picked above, and in Results only when searched for.
            let shown = settings.fallbackChoices(position, matching: query).filter { isSearching || $0.id != picked }
            SettingsGroup(
                isSearching ? "Results" : "Popular",
                note: "Through OpenRouter. \(name) uses it from the next answer, here and on Telegram.",
                refusal: isSearching ? settings.refusal(for: [field]) : nil
            ) {
                if shown.isEmpty {
                    SettingsRow(settings.models.isEmpty ? "Reading OpenRouter's models" : "No model matches") {
                        if settings.models.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                ForEach(shown) { choice in
                    row(choice, isPicked: choice.id == picked)
                }
            }
        }
        .searchable(text: $query, prompt: "Search OpenRouter's models")
        .animation(Motion.flip(reduced: reduceMotion), value: picked)
        .task(id: model.connection.state == .connected) {
            if model.connection.state == .connected {
                await settings.loadModels()
            }
        }
    }

    /// Clears this model, so the chain ends before it and the one after moves up.
    private func none(isPicked: Bool) -> some View {
        let settings = model.assistantSettings
        let field = SettingsField.fallbackModel(position)
        return Button {
            Task {
                await settings.change(field, to: "")
            }
        } label: {
            SettingsRow("None") {
                SymbolTile("xmark", color: Palette.secondaryText)
            } trailing: {
                if settings.pending[field] == "" {
                    ProgressView()
                        .controlSize(.small)
                } else if isPicked {
                    checkmark
                }
            }
        }
        .buttonStyle(.settingsRow)
        .disabled(isPicked || settings.isPending(field))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func row(_ choice: OpenRouterModel, isPicked: Bool) -> some View {
        let settings = model.assistantSettings
        let field = SettingsField.fallbackModel(position)
        let isGoing = settings.pending[field] == choice.id
        return Button {
            Task {
                await settings.change(field, to: choice.id)
            }
        } label: {
            SettingsRow(choice.name, subtitle: ModelPrices.line(choice, company: choice.company, perMillion: false)) {
                BrandTile(choice.icon, fallbackName: choice.company)
            } trailing: {
                if isGoing {
                    ProgressView()
                        .controlSize(.small)
                } else if isPicked {
                    checkmark
                }
            }
        }
        .buttonStyle(.settingsRow)
        .disabled(isPicked || settings.isPending(field))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.highlight)
    }
}
