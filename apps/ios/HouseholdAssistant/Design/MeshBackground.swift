// The page behind everything. In the light it runs from warm white at the top to pale
// sky at the bottom, with the rainbow's hues as faint washes in the corners: rose top
// left, sky down the right, amber on the left, violet at the bottom right. In the dark
// it is the icon's navy, with royal rising from the top left and a breath of gold.
//
// Still behind Chat, slowly drifting behind Talk, and still there too with Reduce
// Motion on.

import SwiftUI

struct MeshBackground: View {
    var isAnimated = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if isAnimated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                    mesh(phase: timeline.date.timeIntervalSinceReferenceDate / 9)
                }
            } else {
                mesh(phase: 0)
            }
            if !reduceTransparency && contrast != .increased,
               let palette = ThemeSelection.shared.palette(for: colorScheme),
               ThemeSelection.shared.theme.atmosphereOpacity > 0 {
                ThemeAtmosphere(theme: ThemeSelection.shared.theme, palette: palette)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func mesh(phase: Double) -> some View {
        // Only the centre point moves; the corners stay pinned to the edges.
        let drift = Float(sin(phase)) * 0.08
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.55], [0.5 + drift, 0.45 - drift], [1, 0.4],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: presetColors ?? (colorScheme == .dark ? darkColors : lightColors)
        )
    }

    private var presetColors: [Color]? {
        guard let colors = ThemeSelection.shared.palette(for: colorScheme)?.page else { return nil }
        let stops = colors.map { Color(themeRGB: $0) }
        return [stops[0], stops[0], stops[1], stops[0], stops[1], stops[2], stops[1], stops[2], stops[2]]
    }

    private var darkColors: [Color] {
        [
            Palette.navyDeep.mix(with: Palette.royal, by: 0.42), Palette.navyDeep.mix(with: Palette.royal, by: 0.14), Palette.navyDeep,
            Palette.navyDeep, Palette.navyDeep, Palette.navyDeep.mix(with: Palette.gold, by: 0.12),
            Palette.navyDeep.mix(with: Palette.navy, by: 0.6), Palette.navy, Palette.navyDeep.mix(with: Palette.navy, by: 0.5),
        ]
    }

    private var lightColors: [Color] {
        [
            Palette.pageWarm.mix(with: Palette.sheenRose, by: 0.18), Palette.pageWarm, Palette.pageSky.mix(with: Palette.sheenSky, by: 0.2),
            Palette.pageWarm.mix(with: Palette.sheenAmber, by: 0.18), Palette.pageWarm.mix(with: Palette.pageSky, by: 0.5), Palette.pageSky.mix(with: Palette.sheenSky, by: 0.14),
            Palette.pageSky.mix(with: Palette.sheenViolet, by: 0.06), Palette.pageSky, Palette.pageSky.mix(with: Palette.sheenViolet, by: 0.2),
        ]
    }
}
