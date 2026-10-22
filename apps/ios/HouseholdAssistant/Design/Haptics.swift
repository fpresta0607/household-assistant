// Every tap the app gives back goes through here, so the Haptics switch in Accessibility
// covers all of them: a checklist ticked, a copy, a message sent, a message lifted for
// reactions, a voice note starting and locking, and a call moving from stage to stage.

import SwiftUI

extension EnvironmentValues {
    /// Whether the app taps back at all. `PhonePreferences` sets it at the root.
    @Entry var isHapticsOn = true
}

extension View {
    /// `feedback` each time `trigger` changes, while haptics are on.
    func haptic<Trigger: Equatable>(_ feedback: SensoryFeedback, trigger: Trigger) -> some View {
        modifier(Haptic(feedback: feedback, trigger: trigger) { _, _ in true })
    }

    /// `feedback` each time `trigger` changes and `condition` holds, while haptics are on.
    func haptic<Trigger: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: Trigger,
        condition: @escaping (_ oldValue: Trigger, _ newValue: Trigger) -> Bool
    ) -> some View {
        modifier(Haptic(feedback: feedback, trigger: trigger, condition: condition))
    }

    /// The feedback `feedback` chooses for each change of `trigger`, if any, while haptics
    /// are on.
    func haptic<Trigger: Equatable>(
        trigger: Trigger,
        _ feedback: @escaping (_ oldValue: Trigger, _ newValue: Trigger) -> SensoryFeedback?
    ) -> some View {
        modifier(ChosenHaptic(trigger: trigger, feedback: feedback))
    }
}

private struct ChosenHaptic<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let feedback: (Trigger, Trigger) -> SensoryFeedback?

    @Environment(\.isHapticsOn) private var isHapticsOn

    func body(content: Content) -> some View {
        let isOn = isHapticsOn
        let feedback = feedback
        return content.sensoryFeedback(trigger: trigger) { oldValue, newValue in
            isOn ? feedback(oldValue, newValue) : nil
        }
    }
}

private struct Haptic<Trigger: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: Trigger
    let condition: (Trigger, Trigger) -> Bool

    @Environment(\.isHapticsOn) private var isHapticsOn

    func body(content: Content) -> some View {
        let isOn = isHapticsOn
        let condition = condition
        return content.sensoryFeedback(feedback, trigger: trigger) { oldValue, newValue in
            isOn && condition(oldValue, newValue)
        }
    }
}
