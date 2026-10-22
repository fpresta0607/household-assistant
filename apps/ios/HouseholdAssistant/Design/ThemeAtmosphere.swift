// Quiet, deterministic artwork shared by every page. Drawn once, without a timer,
// particles, image assets or blur passes. Canvas composites all overlaps before the
// bounded opacity is applied; ThemeContrastTests checks that strongest possible tint.
import SwiftUI

struct ThemeAtmosphere: View {
    let theme: AppTheme
    let palette: ThemeColors

    var body: some View {
        Canvas { context, size in
            let colors = palette.rim.map { Color(themeRGB: $0) }
            switch theme {
            case .aurora: aurora(context, size, colors)
            case .ember: ember(context, size, colors)
            case .starlight: starlight(context, size, colors)
            default: break
            }
        }
        .opacity(theme.atmosphereOpacity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Wide curtains of jade and violet, flowing diagonally beyond the screen edges.
    private func aurora(_ context: GraphicsContext, _ size: CGSize, _ colors: [Color]) {
        let w = size.width
        let h = size.height
        for index in 0..<3 {
            let offset = CGFloat(index) * h * 0.27
            var ribbon = Path()
            ribbon.move(to: CGPoint(x: -w * 0.2, y: offset - h * 0.18))
            ribbon.addCurve(to: CGPoint(x: w * 1.2, y: offset + h * 0.40),
                control1: CGPoint(x: w * 0.55, y: offset - h * 0.1),
                control2: CGPoint(x: w * 0.2, y: offset + h * 0.34))
            ribbon.addLine(to: CGPoint(x: w * 1.2, y: offset + h * 0.54))
            ribbon.addCurve(to: CGPoint(x: -w * 0.2, y: offset - h * 0.08),
                control1: CGPoint(x: w * 0.1, y: offset + h * 0.37),
                control2: CGPoint(x: w * 0.45, y: offset + h * 0.02))
            ribbon.closeSubpath()
            context.fill(ribbon, with: .linearGradient(
                Gradient(colors: [.clear, colors[index], colors[(index + 1) % 3], .clear]),
                startPoint: CGPoint(x: 0, y: offset),
                endPoint: CGPoint(x: w, y: offset + h * 0.4)))
        }
    }

    /// An off-centre autumn sun, with copper contour lines like glazed ceramic.
    private func ember(_ context: GraphicsContext, _ size: CGSize, _ colors: [Color]) {
        let center = CGPoint(x: size.width * 1.04, y: size.height * 0.26)
        let radius = size.width * 0.92
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        context.fill(disc, with: .radialGradient(Gradient(colors: [colors[0], .clear]),
            center: center, startRadius: radius * 0.05, endRadius: radius))
        for index in 0..<3 {
            let ring = radius * (0.62 + CGFloat(index) * 0.15)
            let path = Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring,
                width: ring * 2, height: ring * 2))
            context.stroke(path, with: .color(colors[index]), lineWidth: index == 1 ? 1.5 : 0.7)
        }
    }

    /// Champagne orbit lines and a few fixed stars, kept near the edges of the page.
    private func starlight(_ context: GraphicsContext, _ size: CGSize, _ colors: [Color]) {
        let center = CGPoint(x: size.width * 1.12, y: size.height * 0.12)
        for index in 0..<2 {
            let radius = size.width * (0.7 + CGFloat(index) * 0.14)
            let orbit = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2))
            context.stroke(orbit, with: .color(colors[index]), lineWidth: 0.9)
        }
        let positions: [CGPoint] = [
            CGPoint(x: 0.08, y: 0.12), CGPoint(x: 0.25, y: 0.06),
            CGPoint(x: 0.89, y: 0.32), CGPoint(x: 0.94, y: 0.62),
            CGPoint(x: 0.06, y: 0.73), CGPoint(x: 0.18, y: 0.88),
            CGPoint(x: 0.79, y: 0.91), CGPoint(x: 0.46, y: 0.96),
        ]
        for (index, position) in positions.enumerated() {
            let x = position.x * size.width
            let y = position.y * size.height
            let radius: CGFloat = index.isMultiple(of: 3) ? 4 : 1.5
            var star = Path()
            star.move(to: CGPoint(x: x, y: y - radius))
            star.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x, y: y + radius), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x - radius, y: y), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x, y: y - radius), control: CGPoint(x: x, y: y))
            context.fill(star, with: .color(colors[index % 3]))
        }
    }
}
