// The conversation's photos and videos, full screen: swipe from one to the next, pinch
// or double tap to zoom a photo, the system player for a video, and Save to Photos or
// Share at the bottom. Swipe down or tap the cross to close.
//
// It opens on the one that was tapped, among every photo and video the conversation
// holding it has kept (RoomThread.photosAndVideos). Opened with iOS's zoom out of the
// tapped picture (ZoomTransition), a swipe down is iOS's own, shrinking the picture back
// into its place. With Reduce Motion, where nothing zooms, the viewer follows the finger
// down itself. A photo zoomed in is never swiped away.

import AVKit
import SwiftUI

struct MediaViewer: View {
    let media: RoomMedia
    /// Told which picture is on screen, so closing zooms back into that one's place.
    var onShow: (RoomMedia) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var current: Int?
    @State private var isZoomed = false
    @State private var drop: CGFloat = 0
    /// The pages whose file is on this phone, so Save and Share can offer it.
    @State private var loaded: Set<String> = []
    @State private var notice: String?

    private static let mostDots = 12

    /// Every photo and video of the conversation this one was sent in, or just this one.
    private var pages: [(message: RoomMessage?, media: RoomMedia)] {
        for thread in [model.room.family, model.room.direct] {
            let viewable = thread.photosAndVideos
            if viewable.contains(where: { $0.media.id == media.id }) {
                return viewable.map { (message: $0.message, media: $0.media) }
            }
        }
        return [(message: nil, media: media)]
    }

    var body: some View {
        let shown = pages
        let index = min(max(current ?? 0, 0), shown.count - 1)
        ZStack {
            MeshBackground()
                .opacity(1 - min(abs(drop) / 400, 0.6))
            pager(shown)
                .offset(y: drop)
            chrome(shown, index: index)
                .opacity(drop == 0 ? 1 : 0)
        }
        .onAppear {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                current = shown.firstIndex { $0.media.id == media.id } ?? 0
            }
        }
        .onChange(of: current) { _, page in
            if let page, shown.indices.contains(page) {
                onShow(shown[page].media)
            }
        }
        .interactiveDismissDisabled(isZoomed)
        .animation(Motion.fade, value: notice)
    }

    // MARK: - Pages

    private func pager(_ pages: [(message: RoomMessage?, media: RoomMedia)]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages.indices, id: \.self) { index in
                    page(pages[index].media, isCurrent: index == (current ?? 0))
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .scrollDisabled(isZoomed)
        .ignoresSafeArea()
        .simultaneousGesture(
            // Measured on the screen, because the pager itself moves with the drag.
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onChanged { drag in
                    guard abs(drag.translation.height) > abs(drag.translation.width) else {
                        return
                    }
                    drop = drag.translation.height
                }
                .onEnded { drag in
                    if abs(drag.translation.height) > 140, abs(drag.translation.height) > abs(drag.translation.width) {
                        dismiss()
                    } else {
                        withAnimation(Motion.press(reduced: reduceMotion)) {
                            drop = 0
                        }
                    }
                },
            // Only where iOS's zoom does not already close it with a swipe down.
            including: isZoomed || !reduceMotion ? .subviews : .all
        )
    }

    @ViewBuilder
    private func page(_ item: RoomMedia, isCurrent: Bool) -> some View {
        if item.kind == .video {
            VideoPage(media: item, isCurrent: isCurrent) {
                loaded.insert(item.id)
            }
        } else {
            PhotoPage(media: item, isZoomed: $isZoomed) {
                loaded.insert(item.id)
            }
        }
    }

    // MARK: - Chrome

    private func chrome(_ pages: [(message: RoomMessage?, media: RoomMedia)], index: Int) -> some View {
        let page = pages[index]
        let file = loaded.contains(page.media.id) ? model.media.cachedURL(for: page.media) : nil
        return VStack {
            HStack {
                Button("Close", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .buttonStyle(.glass)
                Spacer()
                if let message = page.message {
                    VStack(spacing: 1) {
                        Text(model.room.participant(message.author)?.name ?? "")
                            .font(.subheadline.weight(.semibold))
                        Text(sentLabel(message.sentAt))
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .foregroundStyle(Palette.text)
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                // Balances the cross, so the name sits in the middle.
                Color.clear
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            Spacer()
            if let notice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .liquidGlass(.regular, in: Capsule())
                    .transition(.opacity)
            }
            HStack {
                Button("Save to Photos", systemImage: "square.and.arrow.down") {
                    if let file {
                        save(file, isVideo: page.media.kind == .video)
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.highlight)
                .frame(width: 46, height: 46)
                .disabled(file == nil)
                Spacer()
                position(of: index, among: pages.count)
                Spacer()
                if let file {
                    ShareLink(item: file) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Palette.highlight)
                            .frame(width: 46, height: 46)
                    }
                    .accessibilityLabel("Share")
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 46, height: 46)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 64)
            .liquidGlass(.regular, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// A dot for each while there are few, "3 of 12" once there are many.
    @ViewBuilder
    private func position(of index: Int, among count: Int) -> some View {
        if count <= 1 {
            EmptyView()
        } else if count <= Self.mostDots {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Palette.highlight : Palette.text.opacity(0.22))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(index + 1) of \(count)")
        } else {
            Text("\(index + 1) of \(count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Palette.secondaryText)
        }
    }

    /// When the picture was sent, as the thread's dividers say it: "Today 9:41".
    private func sentLabel(_ date: Date) -> String {
        let divider = MessageTime.divider(for: date)
        return "\(divider.day) \(divider.time)"
    }

    private func save(_ file: URL, isVideo: Bool) {
        Task {
            notice = await PhotoLibrarySaver.save(file, isVideo: isVideo) ?? "Saved to Photos"
            try? await Task.sleep(for: .seconds(2))
            notice = nil
        }
    }
}

/// A photo page: read from the gateway or this phone, decoded at a size worth zooming.
private struct PhotoPage: View {
    let media: RoomMedia
    @Binding var isZoomed: Bool
    let onLoaded: () -> Void

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var hasFailed = false

    /// Enough pixels to stay sharp at the deepest zoom on the largest phone.
    private static let pixels: CGFloat = 4096

    var body: some View {
        Group {
            if let image {
                ZoomablePhoto(image: image, isZoomed: $isZoomed)
            } else if hasFailed {
                Label("This photo could not be read", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ProgressView()
            }
        }
        .task(id: media.id) {
            guard image == nil, let file = try? await model.media.url(for: media) else {
                hasFailed = image == nil
                return
            }
            image = await MediaThumbnails.image(for: file, isVideo: false, pixels: Self.pixels)
            hasFailed = image == nil
            onLoaded()
        }
    }
}

/// A video page: the system player, playing while it is the page on screen.
private struct VideoPage: View {
    let media: RoomMedia
    let isCurrent: Bool
    let onLoaded: () -> Void

    @Environment(AppModel.self) private var model
    @State private var player: AVPlayer?
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if hasFailed {
                Label("This video could not be read", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ProgressView()
            }
        }
        .task(id: media.id) {
            guard player == nil, let file = try? await model.media.url(for: media) else {
                hasFailed = player == nil
                return
            }
            let player = AVPlayer(url: file)
            self.player = player
            onLoaded()
            if isCurrent {
                try? AudioFocus.take(.playback, mode: .moviePlayback)
                player.play()
            }
        }
        .onChange(of: isCurrent) { _, isShown in
            if isShown {
                play()
            } else {
                pause()
            }
        }
        .onDisappear {
            pause()
        }
    }

    /// A video here plays with its sound, so it takes the phone's sound while it does.
    private func play() {
        guard let player else {
            return
        }
        try? AudioFocus.take(.playback, mode: .moviePlayback)
        player.play()
    }

    private func pause() {
        guard let player, player.rate != 0 else {
            return
        }
        player.pause()
        AudioFocus.giveBack()
    }
}
