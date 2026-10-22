// Right after pairing: one short screen for each thing worth turning on, in order,
// skipping any iOS has already asked about. "Turn on" puts iOS's own question up,
// "Not now" moves on, and Settings can change any of them later.
//
// Location is a choice before it is a permission: sharing stays off unless the person
// picks with whom and for how long and taps Share, and only then does iOS ask. Precise
// Location is a switch of the app's own there, and when iOS keeps the location approximate
// the step stays to say so plainly before it moves on.
//
// Once the microphone is allowed, its step stays too, with bars that move with the room's
// sound from the real input, so the person sees it hears them, until Continue.
//
// Each shows its symbol in a glass circle with a soft glow behind it, holding still: a
// blurred glow swelling for as long as the step was open redrew it on every frame.

import SwiftUI
import UIKit

struct PermissionStepsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    /// Nil until iOS has said which are still to ask.
    @State private var steps: [PermissionKind]?
    @State private var index = 0
    @State private var isAsking = false
    @State private var audience: LocationAudience = .assistant
    @State private var span: LocationSpan = .hour
    @State private var meter = MicrophoneMeter()
    /// Whether the step stays after Turn on, to show what came of it, until Continue.
    @State private var isShowingResult: Bool
    /// The microphone's levels the screenshot tests hold still, in place of the real ones.
    private let heldLevels: [Double]?

    /// The screenshot tests open it on a given step, and on the microphone's with levels
    /// held as if it heard the room.
    init(steps: [PermissionKind]? = nil, index: Int = 0, heldLevels: [Double]? = nil) {
        _steps = State(initialValue: steps)
        _index = State(initialValue: index)
        _isShowingResult = State(initialValue: heldLevels != nil)
        self.heldLevels = heldLevels
    }

    var body: some View {
        ZStack {
            MeshBackground()
            if let steps, index < steps.count {
                // Location's choices at the largest text sizes are taller than a screen,
                // and then the step scrolls.
                ViewThatFits(in: .vertical) {
                    page(steps[index], number: index + 1, of: steps.count)
                    ScrollView {
                        page(steps[index], number: index + 1, of: steps.count)
                    }
                }
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .trailing).combined(with: .opacity))
                .id(steps[index])
            } else {
                ProgressView()
            }
        }
        .foregroundStyle(Palette.text)
        .animation(Motion.arrive(reduced: reduceMotion), value: index)
        .animation(Motion.arrive(reduced: reduceMotion), value: isShowingResult)
        .onDisappear {
            meter.stop()
        }
        .task {
            guard steps == nil else {
                return
            }
            await model.permissions.refresh()
            let offer = PermissionKind.toOffer(model.permissions.statuses)
            if offer.isEmpty {
                finish()
            } else {
                steps = offer
            }
        }
    }

    private func page(_ kind: PermissionKind, number: Int, of count: Int) -> some View {
        step(kind, number: number, of: count)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 520)
    }

    private func step(_ kind: PermissionKind, number: Int, of count: Int) -> some View {
        VStack(spacing: 16) {
            Spacer()
            symbol(kind)
            Text("Step \(number) of \(count)")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Palette.goldText)
                .padding(.top, 8)
            Text(kind.title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(kind.reason)
                .font(kind == .location ? .body : .title3)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
            if kind == .location {
                locationChoices
            }
            if kind == .voice {
                microphoneBars
            }
            Spacer()
            Button {
                if isShowingResult {
                    advance()
                    return
                }
                Task {
                    isAsking = true
                    await turnOn(kind)
                    isAsking = false
                }
            } label: {
                Text(primaryTitle(kind))
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .accentGlass(Palette.royalHighlight)
            .disabled(isAsking)
            if !isShowingResult {
                Button("Not now") {
                    advance()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.highlight)
                .disabled(isAsking)
            }
        }
    }

    private func primaryTitle(_ kind: PermissionKind) -> String {
        if isShowingResult {
            return "Continue"
        }
        return kind == .location ? "Share my location" : "Turn on"
    }

    /// Puts iOS's question up. The microphone's step then stays with its live bars, and the
    /// location's when iOS kept it approximate though Precise is on, to say so.
    private func turnOn(_ kind: PermissionKind) async {
        switch kind {
        case .location:
            await model.shareLocation(with: audience, for: span)
            if model.location.sharing != nil, model.locationPrecision == .keptApproximate {
                isShowingResult = true
                return
            }
        case .voice:
            await model.permissions.request(kind)
            meter.start()
            if meter.isHearing {
                isShowingResult = true
                return
            }
        case .notifications:
            await model.permissions.request(kind)
        }
        advance()
    }

    /// The microphone's level as bars in a glass capsule: still until it is allowed, then
    /// moving with what it hears.
    private var microphoneBars: some View {
        WaveformBars(levels: heldLevels ?? meter.levels, progress: 1, played: Palette.highlight, unplayed: Palette.highlight)
            .frame(height: 36)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: 280)
            .rainbowGlass(in: Capsule())
            .padding(.top, 8)
            .accessibilityElement()
            .accessibilityLabel(isShowingResult ? "The microphone hears you" : "Microphone level")
    }

    /// Precise Location, with what it means for the assistant in plain words, and the way
    /// to iOS Settings when iOS keeps it approximate.
    private var preciseChoice: some View {
        let precision = model.locationPrecision
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding {
                model.location.isPrecise
            } set: { isPrecise in
                Task {
                    await model.sharePrecisely(isPrecise)
                }
            }.animation(Motion.flip(reduced: reduceMotion))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Precise Location")
                        .font(.headline)
                    Text(precision.words(assistant: model.assistantName))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if precision == .keptApproximate {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.highlight)
            }
        }
        .padding(16)
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), isInteractive: true)
    }

    /// With whom, each a glass row with its own line, and for how long.
    private var locationChoices: some View {
        VStack(spacing: 12) {
            ForEach(LocationAudience.allCases, id: \.self) { option in
                Button {
                    audience = option
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title(assistant: model.assistantName))
                                .font(.headline)
                            Text(option.detail(assistant: model.assistantName, otherPerson: model.otherPersonName))
                                .font(.footnote)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: audience == option ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(Palette.highlight)
                    }
                    .padding(16)
                    .rainbowGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(audience == option ? .isSelected : [])
            }
            Picker("For how long", selection: $span) {
                ForEach(LocationSpan.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)
            preciseChoice
                .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    /// The permission's symbol in royal, in a glass circle with the rainbow rim and a
    /// still gold glow behind it.
    private func symbol(_ kind: PermissionKind) -> some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(Palette.highlight)
            .frame(width: 104, height: 104)
            .rainbowGlass(in: Circle())
            .background {
                Circle()
                    .fill(Palette.gold.opacity(0.35))
                    .blur(radius: 24)
                    .scaleEffect(0.95)
                    .opacity(0.6)
            }
            .accessibilityHidden(true)
    }

    private func advance() {
        meter.stop()
        isShowingResult = false
        if let steps, index + 1 < steps.count {
            index += 1
        } else {
            finish()
        }
    }

    private func finish() {
        model.settings.hasOfferedPermissions = true
    }
}
