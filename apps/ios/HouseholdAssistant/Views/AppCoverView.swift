// What covers Steward AI in its own window (CoverWindow): the welcome as the app opens, and
// App Lock while the app is locked or out of sight (AppCover). It is the app's own page,
// the light or dark glass, with the mark in the middle, which plays its motion the first
// time it shows and stands still from then on (WelcomeMark). A tap ends the welcome at
// once. Locked, it shows nothing of the app, and once Face ID is cancelled or fails, an
// Unlock button under the mark asks again. It comes up at once, and lifts away over the
// app once nothing holds it, the mark growing a touch as it fades, or only fading with
// Reduce Motion.

import SwiftUI

struct AppCoverView: View {
    let cover: AppCover

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        ZStack {
            MeshBackground()
            WelcomeMark()
                .scaleEffect(cover.isShown || reduceMotion ? 1 : 1.1)
                // A little above the middle, where the Unlock button below it still sits
                // well clear of the bottom.
                .offset(y: -24)
            if cover.isUnlockShown {
                Button {
                    Task {
                        await cover.unlock()
                    }
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .accentGlass(Palette.highlight)
                .controlSize(.large)
                .offset(y: 88)
                .accessibilityLabel("Unlock Steward AI")
                .transition(.opacity)
            }
        }
        .opacity(cover.isShown ? 1 : 0)
        // Up at once, so the app switcher's picture never catches it halfway, and away on
        // a fade.
        .animation(cover.isShown ? nil : Motion.coverLeave, value: cover.isShown)
        .animation(Motion.fade, value: cover.isUnlockShown)
        .contentShape(Rectangle())
        .onTapGesture {
            cover.endWelcome()
        }
        // VoiceOver stays on the cover rather than reaching the app under it, and hears
        // that the app is locked.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cover.lock.isLocked ? "Steward AI is locked" : "Steward AI")
        .accessibilityAddTraits(.isModal)
    }
}
