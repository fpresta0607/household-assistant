// What a face is made of, before it is cut to a circle or a quarter of one: a person's
// initial on royal when it is this phone's own person and on rose for anyone else, or an
// assistant's emoji on warm white turning gold at the edge.

import SwiftUI

struct FaceTile: View {
    enum Look {
        case ownPerson(initial: String)
        case otherPerson(initial: String)
        /// No emoji yet: a quiet sparkle, never a made-up face.
        case assistant(emoji: String?)
    }

    let look: Look
    let size: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(fill)
            glyph
        }
        .frame(width: size, height: size)
    }

    private var fill: AnyShapeStyle {
        switch look {
        case .ownPerson:
            return AnyShapeStyle(LinearGradient(colors: [Palette.ownFaceTop, Palette.ownFaceBottom], startPoint: .top, endPoint: .bottom))
        case .otherPerson:
            return AnyShapeStyle(LinearGradient(colors: [Palette.otherFaceTop, Palette.otherFace], startPoint: .top, endPoint: .bottom))
        case .assistant:
            return AnyShapeStyle(RadialGradient(
                colors: [.white, Palette.gold.mix(with: .white, by: 0.6)],
                center: UnitPoint(x: 0.32, y: 0.26),
                startRadius: 0,
                endRadius: size * 0.75
            ))
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch look {
        case .ownPerson(let initial), .otherPerson(let initial):
            Text(initial)
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        case .assistant(let emoji?):
            Text(emoji)
                .font(.system(size: size * 0.5))
        case .assistant(nil):
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Palette.goldText)
        }
    }
}

extension FaceTile {
    /// Somebody in the room, drawn as who they are to this phone.
    init(participant: RoomParticipant?, size: CGFloat) {
        let initial = participant.map { String($0.name.prefix(1)).uppercased() } ?? "?"
        if let participant, participant.kind == .assistant {
            self.init(look: .assistant(emoji: participant.emoji), size: size)
        } else if participant?.isOwner == true {
            self.init(look: .ownPerson(initial: initial), size: size)
        } else {
            self.init(look: .otherPerson(initial: initial), size: size)
        }
    }
}
