// The Contacts connector's tile: a person in white on grey, as Apple's Contacts app marks
// itself, since it is the iPhone's own contacts and no company's.

import SwiftUI

struct ContactsTile: View {
    var size: CGFloat = 40

    var body: some View {
        SymbolTile(
            "person",
            fill: AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.78), Color(white: 0.56)],
                startPoint: .top,
                endPoint: .bottom
            )),
            size: size
        )
    }
}
