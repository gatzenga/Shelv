import SwiftUI

struct RecapDetailView: View {
    let entry: RecapRegistryRecord
    let serverId: String

    @ObservedObject private var libraryStore = LibraryViewModel.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @Environment(\.themeColor) private var themeColor
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true
    @State private var songs: [SongWithCount] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showDeleteRecapConfirm = false
    @State private var showDeleteDownloadConfirm = false

    private struct SongWithCount: Identifiable {
        let id: String
        let song: Song
        let playCount: Int
        let originalRank: Int
    }

    private var period: RecapPeriod {
        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
        return RecapPeriod(
            type: type,
            start: Date(timeIntervalSince1970: entry.periodStart),
            end: Date(timeIntervalSince1970: entry.periodEnd)
        )
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                ContentUnavailableView(
                    String(localized: "no_songs"),
                    systemImage: "music.note",
                    description: Text(String(localized: "no_songs_found_for_this_period"))
                )
            } else {
                List {
                    Section {
                        HStack(spacing: 10) {
                            Button {
                                AudioPlayerService.shared.play(songs: songs.map { $0.song }, startIndex: 0)
                            } label: {
                                Label(String(localized: "play"), systemImage: "play.fill")
                                    .frame(minWidth: 100)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(themeColor)
                            .controlSize(.large)

                            Button {
                                AudioPlayerService.shared.playShuffled(songs: songs.map { $0.song })
                            } label: {
                                Label(String(localized: "shuffle"), systemImage: "shuffle")
                                    .frame(minWidth: 100)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            if enableDownloads {
                                recapDownloadContentButtons
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                    }

                    ForEach(Array(songs.enumerated()), id: \.element.id) { idx, entry in
                        Button {
                            AudioPlayerService.shared.play(
                                songs: songs.map { $0.song },
                                startIndex: idx
                            )
                        } label: {
                            songRow(rank: entry.originalRank, entry: entry)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .contextMenu {
                            Button(String(localized: "play")) {
                                AudioPlayerService.shared.play(songs: songs.map { $0.song }, startIndex: idx)
                            }
                            if showInstantMixActions && !offlineMode.isOffline {
                                Button(String(localized: "instant_mix")) {
                                    InstantMixService.playSongMix(for: entry.song)
                                }
                            }
                            Divider()
                            Button(String(localized: "play_next")) {
                                AudioPlayerService.shared.addPlayNext(entry.song)
                                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                            }
                            Button(String(localized: "add_to_queue")) {
                                AudioPlayerService.shared.addToQueue(entry.song)
                                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                            }
                            if showFavoriteActions || showPlaylistActions {
                                Divider()
                                if showFavoriteActions {
                                    Button(String(localized: "add_to_favorites")) {
                                        Task { await libraryStore.toggleStarSong(entry.song) }
                                    }
                                }
                                if showPlaylistActions {
                                    Button(String(localized: "add_to_playlist")) {
                                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: [entry.song.id])
                                    }
                                }
                            }
                            Divider()
                            Button(String(localized: "song_info_details")) {
                                appState.showSongInfo(entry.song)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(period.playlistName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "play_next")) {
                        AudioPlayerService.shared.addPlayNext(songs.map { $0.song })
                        NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                    }
                    .disabled(songs.isEmpty)
                    Button(String(localized: "add_to_queue")) {
                        AudioPlayerService.shared.addToQueue(songs.map { $0.song })
                        NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                    }
                    .disabled(songs.isEmpty)
                    Divider()
                    Button(String(localized: "delete_recap"), role: .destructive) {
                        showDeleteRecapConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(isLoading)
            }
        }
        .task { await load() }
        .alert(String(localized: "delete_downloads_2"), isPresented: $showDeleteDownloadConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                let allSongs = songs.map { $0.song }
                for song in allSongs {
                    downloadStore.deleteSong(song.id)
                }
                downloadStore.unmarkPlaylistDownloaded(id: entry.playlistId)
                NotificationCenter.default.post(name: .showToast, object: String(localized: "downloads_deleted"))
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .alert(String(localized: "delete_recap_2"), isPresented: $showDeleteRecapConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                Task {
                    do {
                        try await RecapStore.shared.deleteEntry(playlistId: entry.playlistId, serverId: serverId)
                        dismiss()
                    } catch {
                        if !(error is CancellationError) {
                            NotificationCenter.default.post(name: .showToast, object: String(localized: "could_not_delete_recap"))
                        }
                    }
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(period.playlistName)
        }
    }

    private func songRow(rank: Int, entry: SongWithCount) -> some View {
        let isTop3 = rank <= 3
        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(isTop3 ? .title3.bold() : .callout.bold())
                .foregroundStyle(isTop3 ? AnyShapeStyle(themeColor) : AnyShapeStyle(.secondary))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)

            CoverArtView(
                url: entry.song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 100) },
                size: 44, cornerRadius: 6
            )
            .overlay {
                NowPlayingOverlay(songId: entry.song.id, size: 44, cornerRadius: 6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.song.title)
                    .font(isTop3 ? .body.bold() : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let artist = entry.song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if enableDownloads {
                DownloadStatusIcon(songId: entry.song.id)
            }
            HStack(spacing: 3) {
                Image(systemName: "play.fill").font(.caption2)
                Text("\(entry.playCount)").font(.caption.monospacedDigit())
            }
            .foregroundStyle(isTop3 ? AnyShapeStyle(themeColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isTop3 ? themeColor : Color.secondary).opacity(0.12))
            .clipShape(Capsule())
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTop3 ? themeColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
        )
        .overlay {
            if isTop3 {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(themeColor.opacity(0.25), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var recapDownloadContentButtons: some View {
        let isMarked = downloadStore.downloadedPlaylistIds.contains(entry.playlistId)
        let remaining = isMarked ? songs.filter { !downloadStore.isDownloaded(songId: $0.song.id) }.count : 0
        if !isMarked && !offlineMode.isOffline {
            Button {
                let allSongs = songs.map { $0.song }
                let missing = allSongs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                downloadStore.markPlaylistDownloaded(id: entry.playlistId, name: period.playlistName, songIds: allSongs.map(\.id))
                NotificationCenter.default.post(name: .showToast, object: String(localized: "download_started"))
            } label: {
                Label(String(localized: "download"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        if isMarked && remaining > 0 && !offlineMode.isOffline {
            Button {
                let allSongs = songs.map { $0.song }
                let missing = allSongs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                downloadStore.syncPlaylistSongIds(entry.playlistId, songIds: allSongs.map(\.id))
                NotificationCenter.default.post(name: .showToast, object: String(localized: "download_started"))
            } label: {
                Label("Rest (\(remaining))", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        if isMarked {
            Button {
                showDeleteDownloadConfirm = true
            } label: {
                Label(String(localized: "delete_downloads"), systemImage: "arrow.down.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        guard let playlist = await libraryStore.loadPlaylistDetail(id: entry.playlistId) else {
            errorMessage = String(localized: "playlist_could_not_be_loaded")
            return
        }
        let playlistSongs = playlist.songs ?? []

        let counts = await PlayLogService.shared.topSongs(
            serverId: serverId,
            from: Date(timeIntervalSince1970: entry.periodStart),
            to: Date(timeIntervalSince1970: entry.periodEnd),
            limit: period.type.songLimit
        )
        let countMap = Dictionary(uniqueKeysWithValues: counts.map { ($0.songId, $0.count) })

        let ranked = playlistSongs.enumerated().map { (idx, song) in
            (rank: idx + 1, song: song, playCount: countMap[song.id] ?? 0)
        }
        let filtered = offlineMode.isOffline
            ? ranked.filter { downloadStore.isDownloaded(songId: $0.song.id) }
            : ranked
        songs = filtered.map { SongWithCount(id: $0.song.id, song: $0.song, playCount: $0.playCount, originalRank: $0.rank) }
        if !offlineMode.isOffline {
            downloadStore.syncPlaylistSongIds(entry.playlistId, songIds: playlistSongs.map(\.id))
        }
    }
}
