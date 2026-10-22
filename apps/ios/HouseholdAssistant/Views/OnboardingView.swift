// The first run, until this phone is paired: what Steward AI is, three things worth
// knowing, whose phone it is, and the code that pairs it. Nothing is typed: Corey or
// Denise sends the code in Telegram, and it is pasted here, or opened as a link. Or the
// person signs in with Apple, and an iPhone nobody linked yet waits for Franco to let
// it in. Once paired, PermissionStepsView offers what is worth turning on.
//
// The welcome shows the app's own icon and the family's faces floating in under it,
// one after another, and a light glides once across Get started when they have. With
// Reduce Motion the faces are simply there and the light never moves.

import SwiftUI

struct OnboardingView: View {
    enum Step: Hashable {
        case welcome, facts, who, code, pairing
    }

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var step: Step
    @State private var member: HouseholdMember?
    /// Why the last paste did not pair, in a plain sentence.
    @State private var refusal: String?
    /// Whether the welcome's faces have floated in.
    @State private var isWelcomed = false
    /// Where the welcome's light is held across Get started, 0 to 1, for a picture of it
    /// mid-glide. Nil lets it glide.
    private let heldGlide: Double?

    /// The screenshot tests open it on any step, and can hold the welcome's light.
    init(step: Step = .welcome, member: HouseholdMember? = nil, refusal: String? = nil, heldGlide: Double? = nil) {
        _step = State(initialValue: step)
        _member = State(initialValue: member)
        _refusal = State(initialValue: refusal)
        self.heldGlide = heldGlide
    }

    var body: some View {
        // Once paired, the first run ends with what is worth turning on.
        if model.isPaired {
            PermissionStepsView()
        } else {
            tour
        }
    }

    private var tour: some View {
        ZStack {
            MeshBackground()
            Group {
                if case .waiting(let person) = model.appleSignIn.phase {
                    AppleSignInWaitingView(member: person)
                } else {
                    switch step {
                    case .welcome:
                        welcome
                    case .facts:
                        facts
                    case .who:
                        who
                    case .code:
                        code
                    case .pairing:
                        pairing
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 520)
            .transition(stepTransition)
            .id(step)
        }
        .foregroundStyle(Palette.text)
        .animation(Motion.arrive(reduced: reduceMotion), value: step)
        .onChange(of: model.pairingAttempt) {
            step = .pairing
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            StewardMark(size: 96)
            Text("Steward AI")
                .font(.largeTitle.weight(.bold))
            Text("The family room, and your own assistant, in one place.")
                .font(.title3)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
            family
                .padding(.top, 8)
            Spacer()
            next("Get started") {
                step = .facts
            }
            .overlay {
                GlidingLight(heldAt: heldGlide)
                    .clipShape(Capsule())
            }
            Button("I already have a code") {
                step = .who
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.highlight)
        }
    }

    /// The four in the family room, floating in one after another.
    private var family: some View {
        let faces: [(name: String, look: FaceTile.Look)] = [
            (HouseholdMember.franco.name, face(of: .franco)),
            (HouseholdMember.gia.name, face(of: .gia)),
            (HouseholdMember.franco.assistantName, .assistant(emoji: HouseholdMember.franco.assistantEmoji)),
            (HouseholdMember.gia.assistantName, .assistant(emoji: HouseholdMember.gia.assistantEmoji)),
        ]
        return HStack(spacing: 16) {
            ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                VStack(spacing: 6) {
                    if case .assistant(let emoji) = face.look {
                        AssistantAvatar(emoji: emoji, size: 56, ring: nil)
                    } else {
                        FaceTile(look: face.look, size: 56)
                            .clipShape(Circle())
                    }
                    Text(face.name)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
                .opacity(isWelcomed ? 1 : 0)
                .offset(y: isWelcomed || reduceMotion ? 0 : 16)
                .animation(Motion.inTurn(index, delay: 0.05, step: 0.05, reduced: reduceMotion), value: isWelcomed)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Franco, Gia, Corey and Denise")
        .onAppear {
            isWelcomed = true
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            fact("link", "Pair right here, with a code Corey or Denise sends you in Telegram, or by signing in with Apple.")
            fact("arrow.down.app", "Updates come through TestFlight. Turn on Automatic Updates for Steward AI there.")
            fact("paperplane", "Telegram keeps working side by side, with the same assistants and the same memory.")
            Spacer()
            next("Continue") {
                step = .who
            }
        }
    }

    private var who: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Who is this iPhone for?")
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Pick yourself. Your assistant comes with you.")
                .font(.body)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            ForEach(HouseholdMember.allCases) { person in
                Button {
                    member = person
                    refusal = nil
                    step = .code
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: -14) {
                            FaceTile(look: face(of: person), size: 52)
                                .clipShape(Circle())
                            AssistantAvatar(emoji: person.assistantEmoji, size: 52, ring: nil)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Palette.text)
                            Text("with \(person.assistantName)")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .padding(16)
                    .rainbowGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(person.name), with \(person.assistantName)")
            }
            Spacer()
            Spacer()
        }
    }

    private var code: some View {
        let person = member ?? .franco
        return VStack(spacing: 24) {
            Spacer()
            AssistantAvatar(emoji: person.assistantEmoji, size: 72, ring: nil)
            Text("Get your code from \(person.assistantName)")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Link(destination: person.telegramLink) {
                Label("Open \(person.assistantName) in Telegram", systemImage: "paperplane.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .tint(Palette.highlight)
            Text("Send /app, then tap the code to copy it and come back.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in
                    paste(strings)
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.extraLarge)
            .tint(Palette.highlight)
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.text)
                    .padding(12)
                    .background(Palette.errorSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Text("or")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
            AppleSignInPanel(member: person)
            Spacer()
            Button("Back") {
                step = .who
            }
            .foregroundStyle(Palette.secondaryText)
        }
    }

    private var pairing: some View {
        VStack(spacing: 24) {
            Spacer()
            switch model.connection.state {
            case .needsPairing(let message), .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Palette.goldText)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                next("Get a new code") {
                    refusal = nil
                    step = member == nil ? .who : .code
                }
            case .pairingPending:
                ProgressView()
                    .controlSize(.large)
                Text("Waiting for this phone to be approved")
                    .font(.title3)
                    .multilineTextAlignment(.center)
            case .connecting, .reconnecting, .disconnected, .connected:
                ProgressView()
                    .controlSize(.large)
                Text("Pairing this phone")
                    .font(.title3)
            }
            Spacer()
        }
    }

    // MARK: - Pieces

    /// Franco in royal and Gia in rose, the way the welcome draws them.
    private func face(of person: HouseholdMember) -> FaceTile.Look {
        let initial = String(person.name.prefix(1))
        return person == .franco ? .ownPerson(initial: initial) : .otherPerson(initial: initial)
    }

    /// Each step slides in from the trailing edge, or only fades with Reduce Motion.
    private var stepTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Palette.goldText)
                .frame(width: 36)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The step's one main action: a glass capsule across the screen, its words and its rim
    /// in royal, never a royal fill.
    private func next(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .accentGlass(Palette.royalHighlight)
    }

    private func paste(_ strings: [String]) {
        guard let code = strings.lazy.compactMap({ PairingCode(text: $0) }).first else {
            refusal = "That is not a Steward AI code. Copy the code from Telegram and try again."
            return
        }
        refusal = nil
        model.pair(code)
    }
}

/// A soft band of light gliding across the button it lies over, from just off its leading
/// edge to just off its trailing one, once, as the welcome settles. It does not come round
/// again: a light that returned every few seconds kept the screen working while it sat
/// there. With Reduce Motion it stays off the button.
private struct GlidingLight: View {
    /// Where the band is held, 0 to 1. Nil lets it glide.
    let heldAt: Double?

    @Environment(\.reducesMotion) private var reduceMotion
    @State private var glides = 0

    var body: some View {
        GeometryReader { geometry in
            if let heldAt {
                band(at: heldAt, across: geometry.size.width)
            } else if !reduceMotion {
                PhaseAnimator([0.0, 1.0], trigger: glides) { travel in
                    band(at: travel, across: geometry.size.width)
                } animation: { travel in
                    // Across with the glide, then back off the leading edge at once.
                    travel == 1 ? Motion.glide : nil
                }
            }
        }
        .task {
            guard heldAt == nil, !reduceMotion else {
                return
            }
            try? await Task.sleep(for: Motion.glideFirst)
            if !Task.isCancelled {
                glides += 1
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func band(at travel: Double, across width: CGFloat) -> some View {
        let bandWidth = width * 0.4
        // A royal shimmer across the button's glass.
        return LinearGradient(
            colors: [.clear, Palette.royalHighlight.opacity(0.22), .clear],
            startPoint: UnitPoint(x: 0, y: 0.35),
            endPoint: UnitPoint(x: 1, y: 0.65)
        )
        .frame(width: bandWidth)
        .offset(x: -bandWidth + (width + bandWidth) * travel)
    }
}
