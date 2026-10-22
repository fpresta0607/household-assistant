// The top of a contact page, the way a contact card opens in Messages: the face, the name,
// who it is, and the actions under them. An assistant's page and the family room's page
// share it, each with its own face, which on a face this phone may change opens the
// choice of photo and crop (FaceChooser, ChangeablePhoto). At the accessibility
// text sizes the actions stack, one to a line, so none of their names is cut short.

import SwiftUI

struct ContactHeader<Face: View, Actions: View>: View {
    let name: String
    let role: String
    let face: Face
    let actions: Actions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(name: String, role: String, @ViewBuilder face: () -> Face, @ViewBuilder actions: () -> Actions) {
        self.name = name
        self.role = role
        self.face = face()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 6) {
            face
                .padding(.bottom, 6)
            Text(name)
                .font(.title.weight(.bold))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Text(role)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
            let actionsLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            actionsLayout {
                actions
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

extension CGFloat {
    /// How far a contact page's face glows past its photo: its shadow's radius and drop.
    static let contactFaceGlowReach: CGFloat = 24
}

extension ContactHeader where Actions == EmptyView {
    init(name: String, role: String, @ViewBuilder face: () -> Face) {
        self.init(name: name, role: role, face: face) {
            EmptyView()
        }
    }
}
