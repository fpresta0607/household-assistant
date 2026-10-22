// A call with the assistant, drawn the way the Phone app draws one: its face and name,
// "Calling…" until the call connects and then how long it has gone on, one line saying
// what the call is doing, and the speaker and Mute beside the red button that ends it.
// Once it ends, "Call ended" for a moment, and the buttons rest.
//
// The line under the time says listening, thinking (or what the assistant is busy with),
// speaking, muted, reconnecting while the gateway's link is down, or on hold while iOS has
// the sound for another call. A soft gold ring round the face follows the voice: the
// assistant's while it talks, the person's while it listens, still while muted, and still
// under Reduce Motion but for its brightness. There is nothing to press to talk or to stop
// the assistant: the person talks over it, as on a call. Mute and Speaker are the person's
// own controls, glass until they are on and white with their colour's rim and glyph while
// they are, as an iPhone call lights them. A call starts on the speaker, so Speaker starts
// lit, and a tap moves the sound to the earpiece and back (CallRouting). While AirPods, a
// headset or the car is connected the sound is theirs, and the button shows which. A
// failure, or today's voice used up, says so in one line under the time, and after a
// failure a tap on the face tries again. The arrow at the top left leaves the screen with
// the call still on, and the call bar brings it back.
//
// A value in, a picture out. `CallView` feeds it the live call, and the screenshot test
// feeds it each state by hand, because listening and speaking are driven by the microphone
// and the voice and cannot be scripted.

import SwiftUI

struct CallScreen: View {
    let session: TalkSession
    let state: CallState
    let routing: CallRouting
    /// 0...1, already smoothed.
    let level: Double
    let onFaceTap: () -> Void
    let onMute: () -> Void
    let onSpeaker: () -> Void
    let onLeave: () -> Void
    let onEnd: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    private static let faceSize: CGFloat = 150
    private static let buttonSize: CGFloat = 76

    /// What the call is doing, as the line under the time says it.
    private enum Status: Equatable {
        case listening
        case muted
        case thinking(AssistantActivity?)
        case speaking
        case reconnecting
        case onHold
    }

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 48)
                face
                Text(model.assistantName)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 28)
                TimelineView(.periodic(from: state.connectedAt ?? .now, by: 1)) { context in
                    Text(state.time(at: context.date))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                        .contentTransition(.opacity)
                }
                .padding(.top, 6)
                if let status {
                    statusLine(status)
                        .padding(.top, 14)
                        .animation(Motion.arrive(reduced: reduceMotion), value: status)
                }
                if let notice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(Palette.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 16)
                }
                Spacer()
                HStack(alignment: .top, spacing: 36) {
                    speakerButton
                    muteButton
                    endButton
                }
                .disabled(isEnded)
                .opacity(isEnded ? 0.4 : 1)
                .padding(.bottom, 56)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if !isEnded {
                    leaveButton
                        .padding(.leading, 20)
                        .padding(.top, 8)
                }
            }
        }
        .animation(Motion.fade, value: state.stage)
        .callStageHaptic(state.stage)
    }

    private var face: some View {
        Button(action: onFaceTap) {
            AssistantAvatar(emoji: model.identity?.emoji, photo: model.assistantPhoto, size: Self.faceSize, ring: model.assistantRing)
                .background {
                    Circle()
                        .stroke(model.assistantRing.ringColor.opacity(0.2 + 0.6 * level), lineWidth: 4)
                        .scaleEffect(reduceMotion ? 1.08 : 1.08 + 0.14 * level)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isFailed)
        .accessibilityLabel(isFailed ? "Try again" : model.assistantName)
    }

    private func statusLine(_ status: Status) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .listening:
                Image(systemName: "waveform")
                    .foregroundStyle(Palette.highlight)
            case .muted:
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(Palette.highlight)
            case .thinking(let activity):
                WorkingRing(activity: activity)
            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Palette.goldText)
            case .reconnecting:
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(Palette.secondaryText)
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            case .onHold:
                Image(systemName: "pause.fill")
                    .foregroundStyle(Palette.secondaryText)
            }
            Text(words(for: status))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
        }
        .font(.headline)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }

    private func words(for status: Status) -> String {
        switch status {
        case .listening:
            return "Listening"
        case .muted:
            return "Muted"
        case .thinking(let activity):
            guard let activity else {
                return "Thinking"
            }
            let phrase = activity.phrase(otherAssistant: model.otherAssistantName)
            return phrase.prefix(1).uppercased() + phrase.dropFirst()
        case .speaking:
            return "Speaking"
        case .reconnecting:
            return "Reconnecting"
        case .onHold:
            return "On hold"
        }
    }

    // MARK: - Controls

    /// A round control as an iPhone call draws one: glass while off, and white with the
    /// person's colour on its rim and glyph while on.
    private func control(_ symbol: String, isOn: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .semibold))
            // Lit controls stay white in both modes, just like the audio play button.
            .foregroundStyle(isOn ? Palette.playOnWhite : Palette.text)
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .background {
                if isOn {
                    Circle()
                        .fill(Color.white)
                        .overlay {
                            Circle().strokeBorder(Palette.highlight.opacity(0.7), lineWidth: 2)
                        }
                        .shadow(color: Palette.shadow, radius: 10, y: 4)
                } else {
                    Color.clear
                        .liquidGlass(.regular.interactive(), in: Circle())
                }
            }
    }

    private func caption(_ words: String) -> some View {
        Text(words)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Palette.secondaryText)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    /// Speaker, flipping between the speaker and the earpiece. While something connected has
    /// the sound, Audio, showing what, and a tap offers iOS's list of where it can go.
    private var speakerButton: some View {
        let routing = self.routing
        return VStack(spacing: 8) {
            if let device = routing.device {
                control(routing.buttonSymbol, isOn: routing.isButtonLit)
                    .overlay {
                        AudioRoutePicker()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(routing.buttonTitle)
                    .accessibilityValue(device.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Chooses where the call's sound goes")
            } else {
                Button(action: onSpeaker) {
                    control(routing.buttonSymbol, isOn: routing.isButtonLit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(routing.buttonTitle)
                .accessibilityValue(routing.isButtonLit ? "On" : "Off")
                .accessibilityAddTraits(routing.isButtonLit ? .isSelected : [])
                .haptic(.selection, trigger: routing.isEarpieceChosen)
            }
            caption(routing.buttonTitle)
        }
        .animation(Motion.flip(reduced: reduceMotion), value: routing)
    }

    private var muteButton: some View {
        let isMuted = session.isMuted
        return VStack(spacing: 8) {
            Button(action: onMute) {
                control("mic.slash.fill", isOn: isMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mute")
            .accessibilityValue(isMuted ? "On" : "Off")
            .accessibilityAddTraits(isMuted ? .isSelected : [])
            .haptic(.selection, trigger: isMuted)
            .animation(Motion.flip(reduced: reduceMotion), value: isMuted)
            caption(isMuted ? "Muted" : "Mute")
        }
    }

    private var endButton: some View {
        VStack(spacing: 8) {
            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
            caption("End")
        }
    }

    /// Leaves the screen with the call still on.
    private var leaveButton: some View {
        Button(action: onLeave) {
            Image(systemName: "chevron.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .liquidGlass(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityHint("The call stays on, with a bar at the top to come back to it.")
    }

    // MARK: - State

    private var isEnded: Bool {
        state.stage == .ended
    }

    private var isFailed: Bool {
        if case .failed = session.phase {
            return true
        }
        return false
    }

    private var status: Status? {
        switch state.stage {
        case .calling, .ended:
            return nil
        case .reconnecting:
            return .reconnecting
        case .onHold:
            return .onHold
        case .connected:
            break
        }
        switch session.phase {
        case .listening:
            return session.isMuted ? .muted : .listening
        case .waiting:
            return .thinking(session.activity)
        case .speaking:
            return .speaking
        case .ended, .failed:
            return nil
        }
    }

    private var notice: String? {
        if case .failed(let reason) = session.phase {
            return reason
        }
        return session.isVoiceUsedUp ? "Today's voice is used up, so \(model.assistantName)'s answers are written in this call's transcript." : nil
    }
}
