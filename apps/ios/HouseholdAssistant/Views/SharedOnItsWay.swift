// Something shared here from another app that the room has not sent yet, on this phone's
// side of its thread: what it carries, and whether it waits for the link. Once the room
// sends it, it is a bubble of its own on its way like any other.

import SwiftUI

struct SharedOnItsWay: View {
    let handoff: ShareHandoff
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Palette.onAccent, Palette.highlight)
            VStack(alignment: .leading, spacing: 1) {
                Text("On its way: \(handoff.summary)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Text(isConnected ? "Shared from another app" : "Sends once Steward AI is connected")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            if isConnected {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}
