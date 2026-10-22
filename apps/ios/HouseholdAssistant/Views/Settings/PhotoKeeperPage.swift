// Photos: the photo and memory keeper. Last month's recap, its best shots, a line about what
// happened and a short video, from the photos the person lets Steward AI read; and the camera
// roll clean-out, near-duplicates, blurry shots and old screenshots, as one batch the person
// reviews. Everything is read and made on this phone (PhotoKeeperModel), and nothing is
// deleted until the person taps Delete on the batch, and then iOS asks once more and keeps
// the photos 30 days in Recently Deleted.

import AVKit
import SwiftUI

struct PhotoKeeperPage: View {
    @State private var keeper = PhotoKeeperModel()
    @State private var player: AVPlayer?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        SettingsPage("Photos") {
            if !keeper.canRead {
                access
            } else {
                recapGroup
                cleanOutGroup
            }
        }
        .task {
            if keeper.canRead, keeper.recap == nil {
                keeper.makeRecap()
            }
        }
        .onDisappear {
            keeper.stop()
            player?.pause()
        }
    }

    private var access: some View {
        SettingsGroup(note: "Steward AI reads your photos on this iPhone only, to pick last month's best shots and to find ones you may want to clear. No photo leaves your iPhone, and nothing is deleted unless you choose it.") {
            if keeper.access == .notDetermined {
                Button {
                    Task {
                        await keeper.askForAccess()
                        keeper.makeRecap()
                    }
                } label: {
                    SettingsRow("Let Steward AI read your photos") {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(Palette.highlight)
                    }
                }
                .buttonStyle(.settingsRow)
            } else {
                OpenIPhoneSettingsRow()
            }
        }
    }

    @ViewBuilder
    private var recapGroup: some View {
        SettingsGroup(keeper.recap?.title ?? "Last month", note: "A new recap is ready on the 1st of every month.") {
            if let recap = keeper.recap {
                VStack(alignment: .leading, spacing: 12) {
                    if let line = keeper.recapLine {
                        Text(line)
                            .font(.body)
                            .foregroundStyle(Palette.text)
                    }
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(recap.best) { photo in
                            LibraryThumbnail(id: photo.id)
                        }
                    }
                    if let player {
                        VideoPlayer(player: player)
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
                if let movie = keeper.movie {
                    ShareLink(item: movie) {
                        SettingsRow("Save or share the video") {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Palette.highlight)
                        }
                    }
                    .buttonStyle(.settingsRow)
                } else {
                    Button {
                        keeper.makeMovie()
                    } label: {
                        SettingsRow("Make the video") {
                            if keeper.isMakingMovie {
                                ProgressView()
                            } else {
                                Image(systemName: "film")
                                    .foregroundStyle(Palette.highlight)
                            }
                        }
                    }
                    .buttonStyle(.settingsRow)
                    .disabled(keeper.isMakingMovie)
                }
            } else if keeper.scan == .recap {
                SettingsRow("Reading last month's photos") {
                    ProgressView(value: keeper.progress)
                        .frame(width: 90)
                }
            } else if keeper.isRecapEmpty {
                SettingsRow("Too few photos last month for a recap") {
                    EmptyView()
                }
            }
        }
        .onChange(of: keeper.movie) { _, movie in
            player = movie.map { AVPlayer(url: $0) }
        }
    }

    @ViewBuilder
    private var cleanOutGroup: some View {
        SettingsGroup(
            "Clean out",
            note: "Favourites are never offered. Delete asks once more, and iOS keeps what you delete in Recently Deleted for 30 days."
        ) {
            if let notice = keeper.notice {
                SettingsRow(notice) {
                    EmptyView()
                }
            }
            if let review = keeper.review {
                ForEach(CleanOutReason.allCases, id: \.self) { reason in
                    let items = review.batch.items(for: reason)
                    if !items.isEmpty {
                        reasonRows(reason, items: items, review: review)
                    }
                }
                Button(role: .destructive) {
                    Task {
                        await keeper.deleteChosen()
                    }
                } label: {
                    SettingsRow(deleteTitle(review.chosen.count)) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
                .buttonStyle(.settingsRow)
                .disabled(review.chosen.isEmpty)
            } else if keeper.scan == .cleanOut {
                SettingsRow("Looking through your photos") {
                    ProgressView(value: keeper.progress)
                        .frame(width: 90)
                }
            } else {
                Button {
                    keeper.findCleanOut()
                } label: {
                    SettingsRow("Find photos to clear", subtitle: "Near-duplicates, blurry shots and old screenshots") {
                        Image(systemName: "sparkles.rectangle.stack")
                            .foregroundStyle(Palette.highlight)
                    }
                }
                .buttonStyle(.settingsRow)
                .disabled(keeper.scan != nil)
            }
        }
    }

    private func reasonRows(_ reason: CleanOutReason, items: [CleanOutItem], review: CleanOutReview) -> some View {
        let isAllChosen = items.allSatisfy { review.isChosen($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(reason.title) (\(items.count))")
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                Spacer()
                Button(isAllChosen ? "Keep all" : "Choose all") {
                    keeper.review?.choose(reason, isChosen: !isAllChosen)
                }
                .font(.callout)
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(items) { item in
                    Button {
                        keeper.review?.toggle(item.id)
                    } label: {
                        LibraryThumbnail(id: item.id)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: review.isChosen(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(review.isChosen(item.id) ? Palette.highlight : .white)
                                    .shadow(radius: 2)
                                    .padding(4)
                            }
                            .opacity(review.isChosen(item.id) ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(review.isChosen(item.id) ? "Chosen to delete" : "Kept")
                }
            }
        }
        .padding(16)
    }

    private func deleteTitle(_ count: Int) -> String {
        count == 1 ? "Delete 1 photo" : "Delete \(count) photos"
    }
}
