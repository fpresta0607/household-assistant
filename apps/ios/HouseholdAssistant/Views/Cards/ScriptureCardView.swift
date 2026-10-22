// A passage set like a page: parchment, the system serif (New York) with room to breathe,
// small gold verse numbers raised above the line, the reference and translation on top,
// and Open in Bible, Copy and Share below.
//
// A passage that arrives in a live reply settles in verse by verse: the page is laid out
// whole from the start, so nothing moves, and each verse rises softly into its place
// after the one before. With Reduce Motion it is simply there.

import SwiftUI

struct ScriptureCardView: View {
    let scripture: ScriptureCard
    let isArriving: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.reducesMotion) private var reduceMotion
    /// How many verses have settled, counting the one settling as part of one.
    @State private var settled: Double
    /// Set by the screenshot tests to hold the passage partway in.
    private let isHeld: Bool

    /// The time each verse takes to settle after the one before.
    private static let secondsPerVerse = 0.55

    init(scripture: ScriptureCard, isArriving: Bool, heldVerses: Double? = nil) {
        self.scripture = scripture
        self.isArriving = isArriving
        isHeld = heldVerses != nil
        _settled = State(initialValue: heldVerses ?? (isArriving ? 0 : Double(scripture.verses.count)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(scripture.reference)
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(scripture.translation)
                    .font(.caption2.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(CardStyle.goldInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(CardStyle.gold.opacity(0.22), in: Capsule())
            }
            passage
                .font(.system(.body, design: .serif))
                .lineSpacing(5)
                .textRenderer(VerseByVerse(settled: settled))
            actions
                .padding(.top, 4)
        }
        .foregroundStyle(CardStyle.parchmentInk)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [CardStyle.parchmentTop, CardStyle.parchmentBottom], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CardStyle.gold.opacity(0.5))
        }
        .shadow(color: CardStyle.goldInk.opacity(0.12), radius: 9, y: 6)
        .onAppear {
            let whole = Double(scripture.verses.count)
            guard settled < whole, !isHeld else {
                return
            }
            withAnimation(reduceMotion ? nil : .linear(duration: Self.secondsPerVerse * whole).delay(0.15)) {
                settled = whole
            }
        }
    }

    /// The verses run together as one paragraph, each led by its number in small gold, and
    /// each marked with its place for `VerseByVerse`.
    private var passage: Text {
        scripture.verses.enumerated().reduce(Text(verbatim: "")) { passage, numbered in
            let (index, verse) = numbered
            let number = Text(verbatim: (index == 0 ? "" : " ") + "\(verse.number)\u{00A0}")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(CardStyle.goldInk)
                .baselineOffset(6)
                .customAttribute(VersePlace(index: index))
            let words = Text(verbatim: verse.text)
                .customAttribute(VersePlace(index: index))
            return Text("\(passage)\(number)\(words)")
        }
    }

    /// Open in Bible, Copy and Share as one set in the page's own dress: gold ink on light
    /// gold with a gold-ink hairline, one height and one corner, so they read on the light
    /// page and none outweighs the passage.
    private var actions: some View {
        HStack(spacing: 8) {
            if let link = scripture.link {
                Button {
                    openURL(link)
                } label: {
                    Label("Open in Bible", systemImage: "book.closed")
                        .padding(.horizontal, 12)
                }
            }
            Spacer(minLength: 0)
            CopyButton(text: scripture.plainText)
                .labelStyle(.iconOnly)
            ShareLink(item: scripture.plainText) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(PageButtonStyle())
        .font(.subheadline.weight(.semibold))
    }
}

/// A button on the scripture page: gold ink on a light gold chip with a gold-ink hairline,
/// 34 points tall and at least as wide, its corners the page's 18 scaled down to 10.
private struct PageButtonStyle: ButtonStyle {
    private static let height: CGFloat = 34
    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(CardStyle.goldInk)
            .frame(minWidth: Self.height, minHeight: Self.height)
            .background(CardStyle.gold.opacity(configuration.isPressed ? 0.28 : 0.14), in: Self.shape)
            .overlay {
                Self.shape.strokeBorder(CardStyle.goldInk.opacity(0.35))
            }
            .contentShape(Self.shape)
    }
}

/// Which verse a run of the passage belongs to, counting from 0.
private struct VersePlace: TextAttribute {
    let index: Int
}

/// Draws the passage where it was laid out, each verse as far settled as `settled` says:
/// verse n fades in and rises the last few points as `settled` goes from n to n + 1.
private struct VerseByVerse: TextRenderer {
    var settled: Double

    var animatableData: Double {
        get { settled }
        set { settled = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                let place = Double(run[VersePlace.self]?.index ?? 0)
                let linear = min(max(settled - place, 0), 1)
                // Eased at both ends, so each verse arrives softly and comes softly to rest.
                let progress = linear * linear * (3 - 2 * linear)
                var verse = context
                verse.opacity = progress
                verse.translateBy(x: 0, y: (1 - progress) * 6)
                verse.draw(run)
            }
        }
    }
}
