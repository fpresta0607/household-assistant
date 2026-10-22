// The models this phone's assistant uses, each chosen from OpenRouter's live list: Text for
// its answers, Vision for reading images, Image for pictures it makes and Video for videos.
//
// Text is the one in use and its second and third, each opening a picker of its own and
// used in that order when the one before fails or is busy, then the popular ones, and a
// search over all of them, each with its company's icon, its price per million tokens and
// a badge. Image and Video are the one in use and every one OpenRouter offers,
// each with its company's icon and name and its price in the unit OpenRouter bills it by,
// read the first time the segment shows. The check moves once the gateway has made the
// change.

import SwiftUI

struct ModelPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var kind: ModelKind
    @State private var query = ""
    @State private var lists = ModelLists()

    init(kind: ModelKind = .text) {
        _kind = State(initialValue: kind)
    }

    var body: some View {
        let settings = model.assistantSettings
        let name = model.assistantName
        // The Image or Video list on screen, read once the gateway can be asked.
        let shownList = kind != .text && model.connection.state == .connected ? kind : nil
        SettingsPage("\(name)'s models") {
            GlassSegmentedControl(choices: ModelKind.allCases, selection: $kind) { $0.label }
            if let current = settings.current {
                switch kind {
                case .text:
                    textModels(current.model, name: name)
                case .vision:
                    madeModels(
                        .vision,
                        inUse: current.visionModel,
                        note: "Reads photos, screenshots and charts you send. \(name) uses this model for the next image in your chat or The Fam."
                    )
                case .image:
                    madeModels(
                        .image,
                        inUse: current.imageModel,
                        note: "Creates pictures. Choose Vision to change the model that reads images you send."
                    )
                case .video:
                    madeModels(
                        .video,
                        inUse: current.videoModel,
                        note: "Creates videos through OpenRouter. Used from the next video you ask \(name) to make."
                    )
                }
            } else {
                SettingsGroup {
                    SettingsRow(settings.errorText ?? "Asking \(name)'s gateway") {
                        if settings.errorText == nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search OpenRouter's models")
        .animation(Motion.flip(reduced: reduceMotion), value: settings.current?.model.id)
        .animation(Motion.flip(reduced: reduceMotion), value: settings.current?.visionModel?.id)
        .animation(Motion.flip(reduced: reduceMotion), value: settings.current?.imageModel?.id)
        .animation(Motion.flip(reduced: reduceMotion), value: settings.current?.videoModel?.id)
        .task(id: model.connection.state == .connected) {
            if model.connection.state == .connected {
                await settings.load()
                await settings.loadModels()
            }
        }
        .task(id: shownList) {
            if let shownList {
                await lists.load(shownList, from: model.connection)
            }
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func textModels(_ inUse: AssistantModel, name: String) -> some View {
        let settings = model.assistantSettings
        let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if !isSearching {
            SettingsGroup("In use", refusal: settings.refusal(for: [.model])) {
                SettingsRow(inUse.name, subtitle: ModelPrices.line(settings.inUse, company: inUse.company, perMillion: true)) {
                    BrandTile(inUse.icon, fallbackName: inUse.company)
                } trailing: {
                    HStack(spacing: 8) {
                        if let badge = settings.inUse?.badge {
                            BadgeLabel(badge: badge)
                        }
                        checkmark
                    }
                }
                ForEach([1, 2], id: \.self) { position in
                    fallbackRow(position, of: inUse)
                }
            }
        }
        let shown = settings.models(matching: query)
        SettingsGroup(
            isSearching ? "Results" : "Popular",
            note: "Through OpenRouter. \(name) uses the new model from the next answer.",
            refusal: isSearching ? settings.refusal(for: [.model]) : nil
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
                row(choice, isInUse: choice.id == inUse.id)
            }
        }
    }

    private func row(_ choice: OpenRouterModel, isInUse: Bool) -> some View {
        let settings = model.assistantSettings
        let isGoing = settings.pending[.model] == choice.id
        return Button {
            Task {
                await settings.change(.model, to: choice.id)
            }
        } label: {
            SettingsRow(choice.name, subtitle: ModelPrices.line(choice, company: choice.company, perMillion: false)) {
                BrandTile(choice.icon, fallbackName: choice.company)
            } trailing: {
                HStack(spacing: 8) {
                    if let badge = choice.badge {
                        BadgeLabel(badge: badge)
                    }
                    if isGoing {
                        ProgressView()
                            .controlSize(.small)
                    } else if isInUse {
                        checkmark
                    }
                }
            }
        }
        .buttonStyle(.settingsRow)
        .disabled(isInUse || settings.isPending(.model))
        .accessibilityAddTraits(isInUse ? .isSelected : [])
    }

    /// The chain's second (1) or third (2) model, its price, and a way to its own picker.
    private func fallbackRow(_ position: Int, of inUse: AssistantModel) -> some View {
        let settings = model.assistantSettings
        let id = settings.fallbackID(position)
        let listed = settings.models.first { $0.id == id }
        let held = inUse.fallbacks.first { $0.id == id }
        let label = position == 1 ? "Second" : "Third"
        return NavigationLink {
            FallbackModelPage(position: position)
        } label: {
            if let id {
                SettingsRow(listed?.name ?? held?.name ?? id, subtitle: "\(label), " + ModelPrices.line(listed, company: listed?.company ?? held?.company ?? "", perMillion: false)) {
                    BrandTile(listed?.icon ?? held?.icon ?? "symbol:cpu", fallbackName: listed?.company ?? held?.company ?? "")
                } trailing: {
                    RowValue(isPending: settings.isPending(.fallbackModel(position)))
                }
            } else {
                SettingsRow("None", subtitle: "\(label), used when the one above fails") {
                    SymbolTile("arrow.turn.down.right", color: Palette.secondaryText)
                } trailing: {
                    RowValue(isPending: settings.isPending(.fallbackModel(position)))
                }
            }
        }
        .buttonStyle(.settingsRow)
    }

    // MARK: - Image and Video

    /// The one in use, then OpenRouter's list of `kind` once it is read, or why it could not
    /// be with a way to try again, or that OpenRouter has none of that kind yet.
    @ViewBuilder
    private func madeModels(_ kind: ModelKind, inUse: ModelChoice?, note: String) -> some View {
        let settings = model.assistantSettings
        let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if let inUse, !isSearching {
            SettingsGroup("In use", refusal: settings.refusal(for: [kind.field])) {
                SettingsRow(inUse.name, subtitle: ModelPrices.line(lists.listed(kind, id: inUse.id), company: inUse.company)) {
                    BrandTile(inUse.icon, fallbackName: inUse.company)
                } trailing: {
                    checkmark
                }
            }
        }
        SettingsGroup(
            isSearching ? "Results" : "On OpenRouter",
            note: note,
            refusal: isSearching || inUse == nil ? settings.refusal(for: [kind.field]) : nil
        ) {
            switch lists.status[kind] {
            case .read(let all)?:
                if all.isEmpty {
                    SettingsRow("OpenRouter offers no \(kind.label.lowercased()) model yet") {
                        EmptyView()
                    }
                } else {
                    let shown = lists.models(kind, matching: query, inUse: inUse?.id)
                    if shown.isEmpty {
                        SettingsRow(isSearching ? "No model matches" : "Only the one in use") {
                            EmptyView()
                        }
                    }
                    ForEach(shown) { choice in
                        row(choice, kind: kind, isInUse: choice.id == inUse?.id)
                    }
                }
            case .failed(let reason)?:
                Button {
                    Task {
                        await lists.load(kind, from: model.connection)
                    }
                } label: {
                    SettingsRow("OpenRouter's models could not be read", subtitle: reason) {
                        Text("Try again")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.highlight)
                    }
                }
                .buttonStyle(.settingsRow)
            case .reading?, nil:
                SettingsRow("Reading OpenRouter's models") {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func row(_ choice: MediaModel, kind: ModelKind, isInUse: Bool) -> some View {
        let settings = model.assistantSettings
        let isGoing = settings.pending[kind.field] == choice.id
        return Button {
            Task {
                await settings.change(kind.field, to: choice.id)
            }
        } label: {
            SettingsRow(choice.name, subtitle: ModelPrices.line(choice, company: choice.company)) {
                BrandTile(choice.icon, fallbackName: choice.company)
            } trailing: {
                if isGoing {
                    ProgressView()
                        .controlSize(.small)
                } else if isInUse {
                    checkmark
                }
            }
        }
        .buttonStyle(.settingsRow)
        .disabled(isInUse || settings.isPending(kind.field))
        .accessibilityAddTraits(isInUse ? .isSelected : [])
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.highlight)
    }
}

/// FAST, SMART or FREE in a small tinted capsule.
private struct BadgeLabel: View {
    let badge: ModelBadge

    var body: some View {
        Text(badge.label)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ink.opacity(0.14), in: Capsule())
    }

    private var ink: Color {
        switch badge {
        case .fast:
            return Color(red: 0x1E / 255, green: 0x8A / 255, blue: 0x50 / 255)
        case .smart:
            return Color(red: 0x6D / 255, green: 0x3F / 255, blue: 0xE0 / 255)
        case .free:
            return Palette.goldText
        }
    }
}
