// The tap a call gives as it moves (CallState.haptic), wherever it shows, on its own screen
// or in the call bar. Each counts from the stage it first saw, so the bar coming up over a
// call already connected does not tap, and neither does the call's screen shown again from
// the bar. Calling is a light tap, connected a success, reconnecting a warning, and the end
// a firm tap, as a call hung up feels.

import SwiftUI

struct CallStageHaptic: ViewModifier {
    let stage: CallState.Stage

    /// The stage last seen here. Nil until the view appears.
    @State private var seen: CallState.Stage?

    func body(content: Content) -> some View {
        content
            .haptic(trigger: seen) { old, new in
                new.flatMap { CallState.haptic(from: old, to: $0) }.map { Self.feedback(for: $0) }
            }
            .onAppear {
                seen = stage
            }
            .onChange(of: stage) { _, new in
                seen = new
            }
    }

    private nonisolated static func feedback(for haptic: CallState.Haptic) -> SensoryFeedback {
        switch haptic {
        case .calling:
            return .impact(weight: .light)
        case .connected:
            return .success
        case .reconnecting:
            return .warning
        case .ended:
            return .impact(weight: .heavy)
        }
    }
}

extension View {
    /// A tap each time the call moves into `stage`.
    func callStageHaptic(_ stage: CallState.Stage) -> some View {
        modifier(CallStageHaptic(stage: stage))
    }
}
