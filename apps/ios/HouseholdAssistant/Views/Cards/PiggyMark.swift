// PocketPiggies' pig, as the approved design draws it: a pastel pig with a gold coin over
// its back, drawn on a 32 point grid and scaled to whatever frame it is given. There is
// no SF Symbol for a pig.

import SwiftUI

struct PiggyMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 32
            context.scaleBy(x: scale, y: scale)

            let coin = Path(ellipseIn: CGRect(x: 15 - 2.8, y: 6 - 2.8, width: 5.6, height: 5.6))
            context.fill(coin, with: .color(CardStyle.hex(0xFFD25E)))

            let outline = Self.outline
            context.fill(outline, with: .linearGradient(
                Gradient(stops: [
                    .init(color: CardStyle.hex(0xFF9FD8), location: 0),
                    .init(color: CardStyle.hex(0xC3A3FF), location: 0.55),
                    .init(color: CardStyle.hex(0x6FDCFF), location: 1),
                ]),
                startPoint: CGPoint(x: 5.5, y: 5.9),
                endPoint: CGPoint(x: 27, y: 27)
            ))
            context.stroke(outline, with: .color(CardStyle.hex(0xE05AA8)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

            let eye = Path(ellipseIn: CGRect(x: 21.6 - 1.1, y: 13.6 - 1.1, width: 2.2, height: 2.2))
            context.fill(eye, with: .color(CardStyle.hex(0x4A2B4A)))

            var tail = Path()
            tail.move(to: CGPoint(x: 5.8, y: 14.6))
            tail.addCurve(to: CGPoint(x: 3.6, y: 12.0), control1: CGPoint(x: 3.9, y: 14.8), control2: CGPoint(x: 2.8, y: 13.4))
            context.stroke(tail, with: .color(CardStyle.hex(0x9B7BFF)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        .accessibilityHidden(true)
    }

    /// The pig's outline: snout to the right, ears up, four short legs.
    private static var outline: Path {
        var path = Path()
        path.move(to: CGPoint(x: 5.5, y: 16))
        path.addCurve(to: CGPoint(x: 15.7, y: 7.2), control1: CGPoint(x: 5.5, y: 10.8), control2: CGPoint(x: 9.9, y: 7.2))
        path.addCurve(to: CGPoint(x: 20.2, y: 8.0), control1: CGPoint(x: 17.3, y: 7.2), control2: CGPoint(x: 18.9, y: 7.5))
        path.addLine(to: CGPoint(x: 22.9, y: 5.9))
        path.addLine(to: CGPoint(x: 22.9, y: 10.3))
        path.addCurve(to: CGPoint(x: 25.4, y: 14.3), control1: CGPoint(x: 24.1, y: 11.4), control2: CGPoint(x: 25.0, y: 12.8))
        path.addLine(to: CGPoint(x: 27, y: 14.3))
        path.addLine(to: CGPoint(x: 27, y: 18.7))
        path.addLine(to: CGPoint(x: 25.3, y: 18.7))
        path.addCurve(to: CGPoint(x: 21.7, y: 22.7), control1: CGPoint(x: 24.6, y: 20.4), control2: CGPoint(x: 23.3, y: 21.8))
        path.addLine(to: CGPoint(x: 21.7, y: 27))
        path.addLine(to: CGPoint(x: 18.4, y: 27))
        path.addLine(to: CGPoint(x: 18.4, y: 24.8))
        path.addCurve(to: CGPoint(x: 15.7, y: 25.0), control1: CGPoint(x: 17.6, y: 24.9), control2: CGPoint(x: 16.7, y: 25.0))
        path.addCurve(to: CGPoint(x: 13.0, y: 24.8), control1: CGPoint(x: 14.7, y: 25.0), control2: CGPoint(x: 13.9, y: 24.9))
        path.addLine(to: CGPoint(x: 13.0, y: 27))
        path.addLine(to: CGPoint(x: 9.7, y: 27))
        path.addLine(to: CGPoint(x: 9.7, y: 23.5))
        path.addCurve(to: CGPoint(x: 5.5, y: 16), control1: CGPoint(x: 7.2, y: 21.9), control2: CGPoint(x: 5.5, y: 19.2))
        path.closeSubpath()
        return path
    }
}
