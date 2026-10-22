// A place an assistant named, pinned on its map: a small gold mark on a white ring, a
// house for home and a pin for anywhere else. Gold is the assistants' presence, and here
// it is only a mark.

import SwiftUI

struct PlacePin: View {
    let label: String?

    var body: some View {
        Image(systemName: label?.lowercased() == "home" ? "house.fill" : "mappin")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Palette.gold, in: Circle())
            .padding(2.5)
            .background(.white, in: Circle())
            .shadow(color: Palette.navy.opacity(0.25), radius: 3, y: 2)
            .accessibilityHidden(true)
    }
}
