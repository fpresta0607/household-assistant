// Pure color tests run on Linux as well as iOS, before any paid Mac build.
import Foundation
import XCTest
@testable import HouseholdAssistant

final class ThemeContrastTests: XCTestCase {
    func testEveryPresetKeepsReadableTextLinksAndRimsAcrossItsSurfaces() throws {
        for theme in AppTheme.allCases where theme != .default {
            for dark in [false, true] {
                let colors = try XCTUnwrap(theme.colors(isDark: dark))
                let surfaces = colors.page + [colors.bubble, colors.surface]
                for background in surfaces {
                    for foreground in [colors.text, colors.secondary, colors.accent, colors.presence] {
                        XCTAssertGreaterThanOrEqual(contrast(foreground, background), 4.5, "\(theme) text against \(background)")
                    }
                    for rim in colors.rim {
                        XCTAssertGreaterThanOrEqual(contrast(rim, background), 3, "\(theme) rim against \(background)")
                    }
                }
                XCTAssertGreaterThanOrEqual(contrast(colors.accentText, colors.accent), 4.5, "\(theme) accent content")
                // Endpoints alone miss contrast dips inside a multicolor gradient.
                for step in 0...20 {
                    let background = mix(colors.ownTop, colors.ownBottom, fraction: Double(step) / 20)
                    XCTAssertGreaterThanOrEqual(contrast(colors.ownText, background), 4.5, "\(theme) own text")
                    XCTAssertGreaterThanOrEqual(contrast(colors.ownMention, background), 4.5, "\(theme) own mention")
                }
            }
        }
    }

    func testAtmospherePreservesTextContrastAcrossTheWholePage() throws {
        for theme in AppTheme.allCases where theme.atmosphereOpacity > 0 {
            for dark in [false, true] {
                let colors = try XCTUnwrap(theme.colors(isDark: dark))
                // Include blends between the mesh's stops, not just their endpoints.
                for first in colors.page {
                    for second in colors.page {
                        for step in 0...10 {
                            let page = mix(first, second, fraction: Double(step) / 10)
                            for tint in colors.rim {
                                let background = mix(page, tint, fraction: theme.atmosphereOpacity)
                                for foreground in [colors.text, colors.secondary, colors.accent, colors.presence] {
                                    XCTAssertGreaterThanOrEqual(contrast(foreground, background), 4.5,
                                        "\(theme) \(dark ? "dark" : "light") atmosphere")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func luminance(_ rgb: UInt32) -> Double {
        let channels = [16, 8, 0].map { shift -> Double in
            let value = Double((rgb >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let values = [luminance(a), luminance(b)]
        return (values.max()! + 0.05) / (values.min()! + 0.05)
    }

    private func mix(_ a: UInt32, _ b: UInt32, fraction: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { result, shift in
            let first = Double((a >> shift) & 255)
            let second = Double((b >> shift) & 255)
            return result | (UInt32((first + (second - first) * fraction).rounded()) << shift)
        }
    }
}
