// A phone that signed in with Apple and nobody linked yet, waiting for Franco to let it
// in from his own phone. It asks its gateway every few seconds while it is on screen,
// and pairs by itself once he says yes.

import SwiftUI

struct AppleSignInWaitingView: View {
    let member: HouseholdMember

    @Environment(AppModel.self) private var model
    @Environment(\.memberName) private var memberName

    /// Every five seconds for an hour, then the person taps to look again.
    private static let checks = 720
    @State private var hasStoppedChecking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .opacity(hasStoppedChecking ? 0 : 1)
            Text("Waiting for \(memberName(.franco))")
                .font(.title.weight(.bold))
            Text("\(memberName(.franco)) sees this iPhone in Steward AI on his own iPhone, under Settings. Once he lets it in, it joins as \(memberName(member)) by itself.")
                .font(.body)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
            if member == .franco {
                Text("If this is your only iPhone, ask whoever runs your household's server for a setup link instead.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if hasStoppedChecking {
                Button("Check again", systemImage: "arrow.clockwise") {
                    hasStoppedChecking = false
                }
                .buttonStyle(.glass)
            }
            Spacer()
            Button("Stop waiting") {
                model.appleSignIn.giveUp()
            }
            .foregroundStyle(Palette.secondaryText)
        }
        .task(id: hasStoppedChecking) {
            guard !hasStoppedChecking else {
                return
            }
            for _ in 0..<Self.checks {
                if let code = await model.appleSignIn.checkWaiting() {
                    model.pairSignedInWithApple(code)
                    return
                }
                guard case .waiting = model.appleSignIn.phase else {
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled {
                    return
                }
            }
            hasStoppedChecking = true
        }
    }
}
