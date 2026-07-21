import Combine
import SwiftUI

struct RecapDetailView: View {
    let entry: RecapRegistryRecord
    let serverId: String

    @ObservedObject private var libraryStore = LibraryStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    private let downloadStore = DownloadStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true

    @State private var songs: [SongWithCount] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentToast: ShelveToast?
    @State private var showDeleteDownloadConfirm = false
    @State private var showDeleteRecapConfirm = false
    @State private var showAddToPlaylist = false
    @Environment(\.dismiss) private var dismiss
    @State private var addToPlaylistSongId: String?
    @State private var isMarkedForOffline: Bool
    @State private var trackedPlaylistSongIDs: [String]
    @State private var downloadedSongIDs: Set<String>

    private let player = AudioPlayerService.shared

    init(entry: RecapRegistryRecord, serverId: String) {
        self.entry = entry
        self.serverId = serverId
        let downloadStore = DownloadStore.shared
        let trackedSongIDs = downloadStore.playlistSongIds[entry.playlistId] ?? []
        _isMarkedForOffline = State(
            initialValue: downloadStore.offlinePlaylistIds.contains(entry.playlistId)
        )
        _trackedPlaylistSongIDs = State(initialValue: trackedSongIDs)
        _downloadedSongIDs = State(
            initialValue: DownloadUIStateHub.shared.downloadedSongIDs(
                in: Set(trackedSongIDs)
            )
        )
    }

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

    private var allSongs: [Song] { songs.map { $0.song } }

    private var relevantDownloadedSongIDsPublisher: AnyPublisher<Set<String>, Never> {
        let songIDs = Set(
            trackedPlaylistSongIDs.isEmpty
                ? allSongs.map(\.id)
                : trackedPlaylistSongIDs
        )
        return DownloadUIStateHub.shared.downloadedSongSubsetPublisher(songIDs: songIDs)
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
                        VStack(spacing: 8) {
                            HStack(spacing: 14) {
                                Button {
                                    player.play(songs: allSongs, startIndex: 0)
                                } label: {
                                    Label(String(localized: "play"), systemImage: "play.fill")
                                        .font(.body).bold()
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(accentColor)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    player.playShuffled(songs: allSongs)
                                } label: {
                                    Label(String(localized: "shuffle"), systemImage: "shuffle")
                                        .font(.body).bold()
                                        .foregroundStyle(accentColor)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(accentColor.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            if enableDownloads && !songs.isEmpty {
                                downloadHeaderButtons()
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { idx, songEntry in
                            Button {
                                player.play(songs: allSongs, startIndex: idx)
                            } label: {
                                songRow(rank: songEntry.originalRank, entry: songEntry)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .personalizedSongSwipeActions(
                                song: songEntry.song,
                                isOffline: offlineMode.isOffline,
                                isFavorite: libraryStore.isSongStarred(songEntry.song),
                                accentColor: accentColor,
                                onPlay: {
                                    player.play(songs: allSongs, startIndex: idx)
                                },
                                onFavorite: {
                                    haptic(.medium)
                                    Task { await libraryStore.toggleStarSong(songEntry.song) }
                                },
                                onAddToPlaylist: {
                                    addToPlaylistSongId = songEntry.song.id
                                    showAddToPlaylist = true
                                },
                                onPlayNext: {
                                    haptic()
                                    player.addPlayNext(songEntry.song)
                                    currentToast = ShelveToast(message: String(localized: "plays_next"))
                                },
                                onAddToQueue: {
                                    haptic()
                                    player.addToQueue(songEntry.song)
                                    currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                                }
                            )
                        }
                    }

                    PlayerBottomSpacer()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(period.playlistName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        player.play(songs: allSongs, startIndex: 0)
                    } label: {
                        Label(String(localized: "play"), systemImage: "play.fill")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        player.playShuffled(songs: allSongs)
                    } label: {
                        Label(String(localized: "shuffle"), systemImage: "shuffle")
                    }
                    .disabled(songs.isEmpty)

                    Divider()

                    Button {
                        player.addPlayNext(allSongs)
                        currentToast = ShelveToast(message: String(localized: "plays_next"))
                    } label: {
                        Label(String(localized: "play_next"), systemImage: "text.insert")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        player.addToQueue(allSongs)
                        currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                    } label: {
                        Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
                    }
                    .disabled(songs.isEmpty)

                    Divider()

                    Button(role: .destructive) {
                        showDeleteRecapConfirm = true
                    } label: {
                        Label(String(localized: "delete_recap"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(isLoading)
            }
        }
        .task { await load() }
        .onReceive(
            downloadStore.$offlinePlaylistIds
                .map { $0.contains(entry.playlistId) }
                .removeDuplicates()
        ) { isMarkedForOffline = $0 }
        .onReceive(
            downloadStore.$playlistSongIds
                .map { $0[entry.playlistId] ?? [] }
                .removeDuplicates()
        ) { trackedPlaylistSongIDs = $0 }
        .onReceive(relevantDownloadedSongIDsPublisher) { downloadedSongIDs = $0 }
        .shelveToast($currentToast)
        .alert(
            String(localized: "delete_downloads"),
            isPresented: $showDeleteDownloadConfirm
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                for song in allSongs {
                    downloadStore.deleteSong(song.id)
                }
                downloadStore.removeOfflinePlaylist(entry.playlistId)
                currentToast = ShelveToast(message: String(localized: "downloads_deleted"))
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .alert(
            String(localized: "delete_recap_2"),
            isPresented: $showDeleteRecapConfirm
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                Task {
                    do {
                        try await RecapStore.shared.deleteEntry(playlistId: entry.playlistId, serverId: serverId)
                        dismiss()
                    } catch {
                        if !(error is CancellationError) {
                            currentToast = ShelveToast(message: String(localized: "could_not_delete_recap"), isError: true)
                        }
                    }
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(period.playlistName)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let songId = addToPlaylistSongId {
                AddToPlaylistSheet(songIds: [songId])
            }
        }
    }

    // MARK: - Row

    private func songRow(rank: Int, entry: SongWithCount) -> some View {
        let isTop3 = rank <= 3
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            AlbumArtView(coverArtId: entry.song.coverArt, size: 100, cornerRadius: 8)
                .frame(width: 52, height: 52)
                .overlay {
                    NowPlayingOverlay(songId: entry.song.id, size: 52, cornerRadius: 8, accentColor: accentColor)
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
            HStack(spacing: 4) {
                SongFavoriteBadge(songId: entry.song.id)
                if enableDownloads {
                    DownloadStatusIcon(songId: entry.song.id)
                }
            }
            playCountBadge(entry.playCount, isTop3: isTop3)
        }
    }

    // MARK: - Shared Components

    private func rankCard<Content: View>(isTop3: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTop3 ? accentColor.opacity(0.08) : Color(.secondarySystemBackground))
            )
            .overlay {
                if isTop3 {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(accentColor.opacity(0.25), lineWidth: 1)
                }
            }
    }

    private func rankLabel(rank: Int, isTop3: Bool) -> some View {
        Text("\(rank)")
            .font(isTop3 ? .title2.bold() : .callout.bold())
            .foregroundStyle(isTop3 ? accentColor : Color.secondary)
            .monospacedDigit()
            .frame(width: 28, alignment: .trailing)
    }

    private func playCountBadge(_ count: Int, isTop3: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.caption2)
            Text("\(count)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(isTop3 ? accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isTop3 ? accentColor : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Download Header

    @ViewBuilder
    private func downloadHeaderButtons() -> some View {
        let isMarked = isMarkedForOffline
        let trackedSongIDs = trackedPlaylistSongIDs.isEmpty
            ? allSongs.map(\.id)
            : trackedPlaylistSongIDs
        let downloadedCount = trackedSongIDs.filter(downloadedSongIDs.contains).count
        let remaining = isMarked ? max(0, trackedSongIDs.count - downloadedCount) : 0
        HStack(spacing: 10) {
            if !isMarked && !offlineMode.isOffline {
                Button {
                    haptic()
                    let missing = allSongs.filter {
                        !DownloadUIStateHub.shared.isSongDownloaded($0.id)
                    }
                    if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                    downloadStore.addOfflinePlaylist(
                        entry.playlistId,
                        name: period.playlistName,
                        songIds: allSongs.map(\.id)
                    )
                    currentToast = ShelveToast(message: String(localized: "download_started"))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text(String(localized: "download"))
                    }
                    .font(.subheadline).bold()
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if isMarked && remaining > 0 && !offlineMode.isOffline {
                Button {
                    haptic()
                    let missing = allSongs.filter {
                        !DownloadUIStateHub.shared.isSongDownloaded($0.id)
                    }
                    if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                    currentToast = ShelveToast(message: String(localized: "download_started"))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text("Rest (\(remaining))")
                    }
                    .font(.subheadline).bold()
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if isMarked {
                Button {
                    haptic()
                    showDeleteDownloadConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: DownloadActionSymbols.delete)
                        Text(String(localized: "delete_downloads_2"))
                    }
                    .font(.subheadline).bold()
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        guard let playlist = await libraryStore.loadPlaylistDetail(id: entry.playlistId) else {
            errorMessage = String(localized: "playlist_could_not_be_loaded")
            return
        }
        let playlistSongs: [Song] = playlist.songs ?? []

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
            ? ranked.filter { DownloadUIStateHub.shared.isSongDownloaded($0.song.id) }
            : ranked
        songs = filtered.map { SongWithCount(id: $0.song.id, song: $0.song, playCount: $0.playCount, originalRank: $0.rank) }
        trackedPlaylistSongIDs = downloadStore.playlistSongIds[entry.playlistId] ?? allSongs.map(\.id)
        downloadedSongIDs = DownloadUIStateHub.shared.downloadedSongIDs(
            in: Set(trackedPlaylistSongIDs)
        )
    }
}
