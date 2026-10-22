// A contact page's face that a tap changes, with a small camera on glass at its foot so it
// looks like it does, as a contact's photo does in Messages while it is edited.

import SwiftUI

struct ChangeablePhoto<Face: View>: View {
    let face: Face

    init(@ViewBuilder face: () -> Face) {
        self.face = face()
    }

    var body: some View {
        face
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.highlight)
                    .frame(width: 32, height: 32)
                    .rainbowGlass(in: Circle())
                    .accessibilityHidden(true)
            }
    }
}
