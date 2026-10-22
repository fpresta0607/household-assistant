// The first web link in a message, unfolded beneath it: the page's picture, its title
// and its site, from LinkPresentation (Media/LinkPreviewStore.swift). The card is its
// final size from the first frame, so the thread does not jump when the page answers.
// A tap opens the page in Safari.

import SwiftUI

struct LinkPreviewCard: View {
    let text: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = LinkPreviewStore.link(in: text) {
            LinkCard(url: url) {
                openURL(url)
            }
        }
    }
}

private struct LinkCard: View {
    let url: URL
    let onOpen: () -> Void

    @State private var preview: LinkPreviewStore.Preview?
    @State private var isLoading: Bool

    private static let width: CGFloat = 252
    private static let pictureHeight: CGFloat = 132

    /// A link already read shows its card in the first frame.
    init(url: URL, onOpen: @escaping () -> Void) {
        self.url = url
        self.onOpen = onOpen
        let kept = LinkPreviewStore.shared.kept(url)
        _preview = State(initialValue: kept)
        _isLoading = State(initialValue: kept == nil)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                picture
                    .frame(width: Self.width, height: Self.pictureHeight)
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview?.title ?? site)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let icon = preview?.icon {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        } else {
                            Image(systemName: "safari")
                                .font(.caption)
                        }
                        Text(site)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Palette.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 11)
                .frame(width: Self.width, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Motion.fade, value: isLoading)
        .task(id: url) {
            guard isLoading else {
                return
            }
            preview = await LinkPreviewStore.shared.preview(for: url)
            isLoading = false
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link, \(preview?.title ?? site)")
        .accessibilityHint("Opens it in Safari")
    }

    private var site: String {
        preview?.site ?? LinkPreviewStore.site(of: url)
    }

    @ViewBuilder
    private var picture: some View {
        if let image = preview?.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .transition(.opacity)
        } else if isLoading {
            ShimmerPlaceholder()
        } else {
            ZStack {
                LinearGradient(colors: [Palette.highlight.opacity(0.35), Palette.navy.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "link")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Palette.text.opacity(0.7))
            }
        }
    }
}
