// A video on its own in a bubble: it plays where it is, on a loop and without sound,
// while it is on screen, with its length in the corner and a speaker to tap for sound.
// Its first frame comes into focus from a blur as it arrives. A tap anywhere else on it
// opens it full screen, zooming out of the bubble.

import AVFoundation
import SwiftUI
import UIKit

struct InlineVideo: View {
    let media: RoomMedia
    let onOpen: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.mediaZoom) private var zoom
    @Environment(\.threadRowVisibility) private var rowVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var poster: UIImage?
    @State private var hasFailed = false
    @State private var isOnScreen = false
    @State private var isMuted = true
    @State private var isReadyForDisplay = false

    var body: some View {
        let size = MediaGrid([media]).size(fitting: MediaGallery.width, maxHeight: MediaGallery.maxHeight)
        ZStack {
            if let poster {
                Image(uiImage: poster)
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
            if let player {
                PlayerSurface(player: player) { ready in
                    isReadyForDisplay = ready
                }
                    .opacity(isReadyForDisplay ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(Motion.reveal(reduced: reduceMotion), value: poster == nil)
        .overlay(alignment: .bottom) {
            if let player {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    chrome(player)
                }
            } else {
                chrome(nil)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MediaGallery.cornerRadius, style: .continuous))
        .zoomSource(media.id, in: zoom)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onScrollVisibilityChange(threshold: 0.6) { isVisible in
            guard rowVisibility == nil else { return }
            isOnScreen = isVisible
            play()
        }
        .onChange(of: rowVisibility?.isVisible, initial: true) { _, visible in
            guard let visible else { return }
            isOnScreen = visible
            play()
        }
        .onChange(of: scenePhase) { _, _ in play() }
        .onAppear {
            if let visible = rowVisibility?.isVisible { isOnScreen = visible }
            play()
        }
        .onDisappear {
            isOnScreen = false
            play()
        }
        .task(id: media.id) {
            await load()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video, \(VoiceNoteGesture.clock(milliseconds: media.durationMs ?? 0))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open full screen", onOpen)
    }

    /// The speaker, the time left and how far it has played.
    private func chrome(_ player: AVPlayer?) -> some View {
        let duration = Double(media.durationMs ?? 0) / 1000
        let played = player.map { CMTimeGetSeconds($0.currentTime()) }.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let progress = duration > 0 ? min(max(played / duration, 0), 1) : 0
        return VStack(spacing: 0) {
            HStack {
                Button {
                    toggleSound()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .frame(width: 30, height: 30)
                        .liquidGlass(.regular.interactive(), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .disabled(player == nil)
                .accessibilityLabel(isMuted ? "Turn on sound" : "Turn off sound")
                Spacer()
                if media.durationMs != nil {
                    Text(VoiceNoteGesture.clock(milliseconds: Int((duration - played) * 1000)))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.navyDeep.opacity(0.45), in: Capsule())
                        .padding(.trailing, 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 2)
            Rectangle()
                .fill(.white.opacity(0.35))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.white)
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .accessibilityHidden(true)
        }
    }

    private func load() async {
        guard !media.isPending, player == nil else {
            return
        }
        guard let file = try? await model.media.url(for: media) else {
            guard !Task.isCancelled else { return }
            hasFailed = true
            return
        }
        let size = MediaGrid([media]).size(fitting: MediaGallery.width, maxHeight: MediaGallery.maxHeight)
        poster = await MediaThumbnails.image(for: file, isVideo: true, pixels: max(size.width, size.height) * displayScale)
        guard !Task.isCancelled else { return }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: file))
        self.player = player
        play()
    }

    /// Plays while it is on screen, and nowhere else.
    private func play() {
        guard let player else {
            return
        }
        if isOnScreen && scenePhase == .active {
            player.play()
        } else {
            player.pause()
            // Off screen it goes quiet again, and gives back the sound it took.
            if !isMuted {
                isMuted = true
                player.isMuted = true
                AudioFocus.giveBack()
            }
        }
    }

    private func toggleSound() {
        guard let player else {
            return
        }
        if isMuted {
            // Sound plays the way a video does even with the ring switch on silent.
            try? AudioFocus.take(.playback, mode: .moviePlayback)
        } else {
            AudioFocus.giveBack()
        }
        isMuted.toggle()
        player.isMuted = isMuted
    }
}

/// The player's picture, filling its box.
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let onReady: (Bool) -> Void

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.onReady = onReady
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.onReady = onReady
        view.playerLayer.player = player
    }
}

private final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()
    var onReady: ((Bool) -> Void)?
    private var readiness: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.addSublayer(playerLayer)
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor [weak self] in
                self?.onReady?(ready)
            }
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
