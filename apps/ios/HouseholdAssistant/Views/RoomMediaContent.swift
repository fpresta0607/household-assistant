// What a message carries, inside its bubble: its photos and videos as one gallery, or a
// lone video playing where it is, then each voice note with its waveform and each file
// as a card. Each is read from the gateway the first time it shows and kept on this
// phone after that.

import AVFoundation
import SwiftUI
import UIKit

struct RoomMediaContent: View {
    let media: [RoomMedia]
    /// The message they are in, which each voice note's words are kept open by.
    let messageId: String
    let isOwn: Bool
    /// The bubble's own text colour, which differs between a person's bubble and an
    /// assistant's cream one.
    let foreground: Color
    /// What a voice reply says in words, folded under its voice note rather than shown.
    var spokenWords: String? = nil
    let onOpen: (RoomMedia) -> Void

    var body: some View {
        let visual = media.filter(\.kind.isVisual)
        VStack(alignment: .leading, spacing: 6) {
            if visual.count == 1, let video = visual.first, video.kind == .video {
                InlineVideo(media: video) {
                    onOpen(video)
                }
            } else if !visual.isEmpty {
                MediaGallery(media: visual, onOpen: onOpen)
            }
            // By place rather than id: the same file sent twice in one message is one hash.
            ForEach(Array(media.enumerated()), id: \.offset) { index, item in
                switch item.kind {
                case .voice:
                    VoiceNoteBubble(
                        media: item,
                        note: VoiceNoteDisclosures.key(message: messageId, note: index),
                        isOwn: isOwn,
                        foreground: foreground,
                        spokenWords: spokenWords
                    )
                case .file:
                    FileCard(media: item, isOwn: isOwn, foreground: foreground)
                case .photo, .video:
                    EmptyView()
                }
            }
        }
    }
}

/// A voice note: play, the waveform with the part already heard filled in, its real
/// length, and the speed chip. The play button only plays. A tap anywhere else on the note
/// shows a small Transcript under it, and a tap on that unfolds its words: a voice reply's
/// own words, what the gateway heard in the note, which is what the assistant answered to,
/// or, for a note it has no words for, what this phone heard. Until it is tapped the note
/// shows only itself, and it does again once it has left the screen (VoiceNoteDisclosures),
/// so words heard after it was drawn never change its height. With transcripts off in
/// Accessibility the note is never heard and shows no words.
///
/// A note the gateway kept without a length reads it from the file once it is on this
/// phone, rather than saying 0:00.
private struct VoiceNoteBubble: View {
    let media: RoomMedia
    /// Which note it is, for what it shows of its words (VoiceNoteDisclosures).
    let note: String
    let isOwn: Bool
    let foreground: Color
    /// A voice reply's words, which its transcript is when there are any.
    let spokenWords: String?

    @Environment(AppModel.self) private var model
    @Environment(ThreadListState.self) private var list
    @State private var player = VoiceNotePlayer.shared
    @State private var url: URL?
    @State private var hasFailed = false
    @State private var copiedTranscript = false
    /// The length read from the file, for a note the gateway kept without one.
    @State private var measuredMs: Int?

    init(media: RoomMedia, note: String, isOwn: Bool, foreground: Color, spokenWords: String?) {
        self.media = media
        self.note = note
        self.isOwn = isOwn
        self.foreground = foreground
        let trimmed = spokenWords?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.spokenWords = trimmed?.isEmpty == false ? trimmed : nil
    }

    var body: some View {
        let words = spokenWords
            ?? (model.settings.shouldShowTranscripts ? VoiceNoteTranscripts.shared.words(for: media, at: url) : nil)
        let shown = list.voiceNotes.shown(note)
        VStack(alignment: .leading, spacing: 4) {
            controls
                .contentShape(Rectangle())
                .onTapGesture {
                    if words != nil {
                        list.voiceNotes.tapNote(note)
                    }
                }
            if let words, let shown {
                transcript(words, isOpen: shown == .words)
            }
        }
        .accessibilityActions {
            if words != nil {
                Button(shown == .words ? "Hide the transcript" : "Show the transcript") {
                    list.voiceNotes.toggleWords(note)
                }
            }
        }
        .task(id: media.id) {
            guard !media.isPending, url == nil else {
                return
            }
            do {
                url = try await model.media.url(for: media)
            } catch {
                hasFailed = true
            }
        }
        .task(id: url) {
            guard media.durationMs == nil, let url else {
                return
            }
            if let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds.isFinite {
                measuredMs = Int((duration.seconds * 1000).rounded())
            }
        }
    }

    private var controls: some View {
        let isCurrent = player.current == media.id
        return HStack(spacing: 12) {
            Button {
                if let url {
                    player.toggle(media.id, at: url)
                }
            } label: {
                // White with a royal glyph on every bubble, and a royal ring where the bubble
                // is not royal itself.
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.playOnWhite)
                    .frame(width: 38, height: 38)
                    .background(Color.white, in: Circle())
                    .overlay {
                        if !isOwn {
                            Circle()
                                .strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1.5)
                        }
                    }
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .accessibilityLabel(isCurrent && player.isPlaying ? "Pause voice note" : "Play voice note")

            TimelineView(.animation(minimumInterval: 1 / 30, paused: !(isCurrent && player.isPlaying))) { _ in
                WaveformBars(
                    levels: VoiceNoteBars.shared.levels(for: media, at: url),
                    progress: player.progress(of: media.id),
                    played: isOwn ? .white : Palette.highlight,
                    unplayed: foreground.opacity(0.35)
                )
                .frame(height: 28)
                .frame(minWidth: 120, maxWidth: 170)
            }
            .accessibilityHidden(true)

            VStack(alignment: .trailing, spacing: 2) {
                Text(media.durationMs.map(VoiceNoteGesture.clock(milliseconds:)) ?? measuredMs.map(VoiceNoteGesture.clock(milliseconds:)) ?? "-:--")
                    .font(.caption.monospacedDigit())
                if isCurrent {
                    Button(player.speed.label) {
                        player.speed = player.speed.next
                    }
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(foreground.opacity(0.18), in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityLabel("Speed \(player.speed.label)")
                } else if hasFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                }
            }
            .foregroundStyle(foreground)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// A small Transcript that unfolds the words on a soft panel of the bubble's own
    /// colour, and folds them away again.
    private func transcript(_ words: String, isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                list.voiceNotes.tapDisclosure(note)
            } label: {
                HStack(spacing: 4) {
                    Text("Transcript")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide the transcript" : "Show the transcript")
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = words
                            copiedTranscript = true
                        } label: {
                            Label(copiedTranscript ? "Copied" : "Copy", systemImage: copiedTranscript ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(copiedTranscript ? "Transcript copied" : "Copy transcript")
                        .accessibilityIdentifier("voice-note.copy-transcript")
                    }
                    Text(words)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(foreground.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(foreground.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onDisappear { copiedTranscript = false }
                .task(id: copiedTranscript) {
                    guard copiedTranscript else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    copiedTranscript = false
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The bars of a voice note, filled up to `progress`.
struct WaveformBars: View {
    let levels: [Double]
    let progress: Double
    let played: Color
    let unplayed: Color

    var body: some View {
        GeometryReader { geometry in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let width = max((geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Double(index) / Double(count) < progress ? played : unplayed)
                        .frame(width: width, height: max(geometry.size.height * level, 3))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
