// The same live reading preferences for SwiftUI and the Markdown renderer's UIKit text.
// Fonts in a parsed document are concrete UIFonts: changing only SwiftUI's environment
// cannot update them. The style is also part of the document cache key.

import SwiftStreamingMarkdown
import SwiftUI
import UIKit

struct ReadingStyle: Hashable {
    var size: DynamicTypeSize = .large
    var isBold = false
    var theme = AppTheme.default

    static let standard = ReadingStyle()

    /// Native selection uses the same resolved font as the message it came from.
    var selectionFont: UIFont { fonts(points: 17, lineHeight: 26).normal }

    var config: MarkdownRenderConfig {
        let body = fonts(points: 17, lineHeight: 26)
        let small = fonts(points: 15, lineHeight: 20)
        let code = fonts(points: 15, lineHeight: 20, monospaced: true)
        let heading = TextFonts(
            normal: body.bold!, italic: body.boldItalic, bold: body.bold,
            boldItalic: body.boldItalic, preferredLetterSpacing: 0,
            preferredLineHeight: body.preferredLineHeight
        )
        let standard = MarkdownRenderConfig.default
        let table = standard.tableStyle
        let inline = standard.inlineStyle
        return MarkdownRenderConfig(
            blockQuoteStyle: .init(textFonts: body, textColor: text(standard.blockQuoteStyle.textColor)),
            headingStyle: .init(
                h1Font: heading, h2Font: heading, h3Font: heading,
                h4Font: heading, h5Font: heading, h6Font: heading,
                textColor: text(standard.headingStyle.textColor)
            ),
            orderedListStyle: .init(textFonts: body, textColor: text(standard.orderedListStyle.textColor)),
            paragraphStyle: .init(textFonts: body, textColor: text(standard.paragraphStyle.textColor)),
            tableStyle: .init(
                textFonts: small, headerTextColor: text(table.headerTextColor),
                regularTextColor: text(table.regularTextColor), headerBackgroundColor: table.headerBackgroundColor,
                borderColor: table.borderColor, actionButtonColor: table.actionButtonColor
            ),
            inlineStyle: .init(
                boldTextColor: text(inline.boldTextColor), linkTextFont: heading.normal,
                linkTextColor: Palette.themed(\.accent, theme: theme, fallback: Palette.goldText), codeTextFont: code.normal,
                codeTextColor: inline.codeTextColor, codeBackgroundColor: inline.codeBackgroundColor,
                codeUnderlineColor: inline.codeUnderlineColor
            ),
            codeBlockConfig: .init(
                theme: standard.codeBlockConfig.theme,
                backgroundColor: standard.codeBlockConfig.backgroundColor,
                foregroundColor: standard.codeBlockConfig.foregroundColor,
                codeTextFonts: code, chromeTextFonts: small
            ),
            // Disable the library's "Select more text" sheet only. Its paragraphs
            // remain native selectable UITextViews, including double-tap selection.
            textSelectionConfig: TextSelectionConfig(isEnabled: false)
        )
    }

    private func text(_ fallback: Color) -> Color {
        Palette.themed(\.text, theme: theme, fallback: fallback)
    }

    private func fonts(points: CGFloat, lineHeight: CGFloat, monospaced: Bool = false) -> TextFonts {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let metrics = UIFontMetrics(forTextStyle: .body)
        let scaled = metrics.scaledValue(for: points, compatibleWith: traits)
        func font(_ weight: UIFont.Weight, italic: Bool = false) -> UIFont {
            let base = monospaced
                ? UIFont.monospacedSystemFont(ofSize: scaled, weight: weight)
                : UIFont.systemFont(ofSize: scaled, weight: weight)
            guard italic, let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(.traitItalic)
            ) else { return base }
            return UIFont(descriptor: descriptor, size: scaled)
        }
        let normal: UIFont.Weight = isBold ? .semibold : .regular
        let strong: UIFont.Weight = isBold ? .bold : .semibold
        return TextFonts(
            normal: font(normal), italic: font(normal, italic: true),
            bold: font(strong), boldItalic: font(strong, italic: true),
            preferredLetterSpacing: monospaced ? -0.12 : 0,
            preferredLineHeight: metrics.scaledValue(for: lineHeight, compatibleWith: traits)
        )
    }

    private var contentSizeCategory: UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

extension EnvironmentValues {
    /// Resolved at the app root and carried through the thread's separate UIKit hosts.
    /// A hosted row must not resolve Bold Text again from its own platform defaults.
    @Entry var readingStyle: ReadingStyle = .standard
}
