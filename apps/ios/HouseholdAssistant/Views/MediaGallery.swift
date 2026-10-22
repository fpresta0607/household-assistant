// A message's photos and videos as one picture: a lone photo at its own shape, several
// as a tidy grid with "+2" over the last tile for the rest (Model/MediaGrid.swift). Every
// tile is at its final size from the start and holds a still placeholder until its
// picture arrives, which comes into focus from a blur. A tap opens that one full screen, zooming out of its tile,
// where the rest are a swipe away.

import SwiftUI

struct MediaGallery: View {
    let media: [RoomMedia]
    let onOpen: (RoomMedia) -> Void

    @Environment(\.mediaZoom) private var zoom

    static let width: CGFloat = 240
    static let maxHeight: CGFloat = 320
    static let cornerRadius: CGFloat = 14
    private static let gap: CGFloat = 2

    var body: some View {
        let grid = MediaGrid(media)
        let size = grid.size(fitting: Self.width, maxHeight: Self.maxHeight)
        ZStack(alignment: .topLeading) {
            ForEach(grid.tiles, id: \.index) { tile in
                let frame = Self.place(tile.frame, in: size)
                let item = media[tile.index]
                MediaTile(
                    media: item,
                    overflow: tile.index == grid.tiles.count - 1 ? grid.overflow : 0,
                    size: frame.size
                )
                .frame(width: frame.width, height: frame.height)
                .zoomSource(item.id, in: zoom)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpen(item)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.kind == .video ? "Video" : "Photo")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    onOpen(item)
                }
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// A tile's place in points, with a hairline between it and its neighbours but none
    /// along the box's own edges.
    private static func place(_ unit: CGRect, in size: CGSize) -> CGRect {
        let half = gap / 2
        let left = unit.minX > 0 ? half : 0
        let top = unit.minY > 0 ? half : 0
        let right = unit.maxX < 1 ? half : 0
        let bottom = unit.maxY < 1 ? half : 0
        return CGRect(
            x: unit.minX * size.width + left,
            y: unit.minY * size.height + top,
            width: unit.width * size.width - left - right,
            height: unit.height * size.height - top - bottom
        )
    }

    private var label: String {
        let photos = media.filter { $0.kind == .photo }.count
        let videos = media.count - photos
        var parts: [String] = []
        if photos > 0 {
            parts.append(photos == 1 ? "Photo" : "\(photos) photos")
        }
        if videos > 0 {
            parts.append(videos == 1 ? "Video" : "\(videos) videos")
        }
        return parts.joined(separator: " and ")
    }
}

/// One photo or video in the grid: its picture once read, a video's length, and the
/// count of the rest on the last tile.
private struct MediaTile: View {
    let media: RoomMedia
    let overflow: Int
    let size: CGSize

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var hasFailed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(Motion.blurUpTransition(reduced: reduceMotion))
            } else if hasFailed {
                Rectangle()
                    .fill(Palette.surface)
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ShimmerPlaceholder()
            }
            if media.kind == .video, overflow == 0 {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.mediaGlassText)
                    .frame(width: 40, height: 40)
                    .liquidGlass(.regular, in: Circle())
                if let durationMs = media.durationMs {
                    Text(VoiceNoteGesture.clock(milliseconds: durationMs))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Palette.navyDeep.opacity(0.45), in: Capsule())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            if overflow > 0 {
                Palette.navyDeep.opacity(0.42)
                Text("+\(overflow)")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .animation(Motion.reveal(reduced: reduceMotion), value: image == nil)
        .task(id: media.id) {
            await load()
        }
    }

    private func load() async {
        guard !media.isPending, image == nil else {
            return
        }
        guard let file = try? await model.media.url(for: media) else {
            hasFailed = true
            return
        }
        image = await MediaThumbnails.image(
            for: file,
            isVideo: media.kind == .video,
            pixels: max(size.width, size.height) * displayScale
        )
        hasFailed = image == nil
    }
}
