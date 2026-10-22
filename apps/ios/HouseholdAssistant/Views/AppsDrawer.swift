// The drawer that springs out of the composer's plus when it is tapped: each way to add
// to a message as a tile, like an app on the home screen, a link and where you are among
// them, and Search, which looks through the whole conversation (CFO notes section 5). Its
// rows rise into place one after another, or with Reduce Motion fade in with it.
// Each tile is white with its glyph in royal, Photos' with a glimmer of gold, never a
// coloured fill.

import SwiftUI

struct AppsDrawer: View {
    enum Item: String, CaseIterable, Identifiable {
        case photos, camera, files, scan, contact, link, location, search

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .photos:
                return "Photos"
            case .camera:
                return "Camera"
            case .files:
                return "Files"
            case .scan:
                return "Scan a document"
            case .contact:
                return "Contact"
            case .link:
                return "Link"
            case .location:
                return "Location"
            case .search:
                return "Search"
            }
        }

        var symbol: String {
            switch self {
            case .photos:
                return "photo.on.rectangle.angled"
            case .camera:
                return "camera.fill"
            case .files:
                return "folder.fill"
            case .scan:
                return "doc.viewfinder"
            case .contact:
                return "person.crop.circle.fill"
            case .link:
                return "link"
            case .location:
                return "location.fill"
            case .search:
                return "magnifyingglass"
            }
        }
    }

    let onPick: (Item) -> Void

    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isOpen = false

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to your message")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 4)
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(Array(Item.allCases.enumerated()), id: \.element) { index, item in
                    Button {
                        onPick(item)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(glyph(for: item))
                                .frame(width: 54, height: 54)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .strokeBorder(Palette.highlight.opacity(0.28), lineWidth: 1)
                                }
                                .shadow(color: Palette.shadow, radius: 7, y: 6)
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.secondaryText)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isOpen ? 1 : 0)
                    .offset(y: isOpen || reduceMotion ? 0 : 8)
                    .animation(Motion.inTurn(index / Self.columns.count, delay: 0.06, step: 0.06, reduced: reduceMotion), value: isOpen)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onAppear {
            isOpen = true
        }
    }

    /// Royal glyphs, and Photos' with the gold running through it.
    private func glyph(for item: Item) -> AnyShapeStyle {
        guard item == .photos else {
            return AnyShapeStyle(Palette.highlight)
        }
        return AnyShapeStyle(LinearGradient(colors: [Palette.gold, Palette.highlight], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
