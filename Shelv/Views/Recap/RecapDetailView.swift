import SwiftUI

struct RecapDetailView: View {
    let entry: RecapRegistryRecord
    let serverId: String

    @ObservedObject private var libraryStore = LibraryStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    @State private var songs: [SongWithCount] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentToast: ShelveToast?
    @State private var showAddToPlaylist = false
    @State private var addToPlaylistSongId: String?

    private let player = AudioPlayerService.shared

    private struct SongWithCount: Identifiable {
        let id: String
        let song: Song
        let playCount: Int
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
                    tr("No Songs", "Keine Titel"),
                    systemImage: "music.note",
                    description: Text(tr("No songs found for this period.", "Keine Titel für diesen Zeitraum gefunden."))
                )
            } else {
                List {
                    Section {
                        VStack(spacing: 8) {
                            HStack(spacing: 14) {
                                Button {
                                    player.play(songs: allSongs, startIndex: 0)
                                } label: {
                                    Label(tr("Play", "Abspielen"), systemImage: "play.fill")
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
                                    Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
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
                                songRow(rank: idx + 1, entry: songEntry)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    haptic(); player.addToQueue(songEntry.song)
                                    currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                } label: {
                                    Image(systemName: "text.badge.plus")
                                }
                                .tint(accentColor)

                                Button {
                                    haptic(); player.addPlayNext(songEntry.song)
                                    currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                                } label: {
                                    Image(systemName: "text.insert")
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if enableFavorites && !offlineMode.isOffline {
                                    Button {
                                        haptic(.medium); Task { await libraryStore.toggleStarSong(songEntry.song) }
                                    } label: {
                                        Image(systemName: libraryStore.isSongStarred(songEntry.song) ? "heart.slash" : "heart.fill")
                                    }
                                    .tint(.pink)
                                }
                                if enablePlaylists && !offlineMode.isOffline {
                                    Button {
                                        addToPlaylistSongId = songEntry.song.id
                                        showAddToPlaylist = true
                                    } label: {
                                        Image(systemName: "music.note.list")
                                    }
                                    .tint(accentColor)
                                }
                            }
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
                        Label(tr("Play", "Abspielen"), systemImage: "play.fill")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        player.playShuffled(songs: allSongs)
                    } label: {
                        Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
                    }
                    .disabled(songs.isEmpty)

                    Divider()

                    Button {
                        player.addPlayNext(allSongs)
                        currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                    } label: {
                        Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        player.addToQueue(allSongs)
                        currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                    } label: {
                        Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
                    }
                    .disabled(songs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(isLoading)
            }
        }
        .task { await load() }
        .shelveToast($currentToast)
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
        let isMarked = downloadStore.offlinePlaylistIds.contains(entry.playlistId)
        HStack(spacing: 10) {
            if !isMarked && !offlineMode.isOffline {
                Button {
                    haptic()
                    let missing = allSongs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                    if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                    downloadStore.addOfflinePlaylist(entry.playlistId, songIds: allSongs.map(\.id))
                    currentToast = ShelveToast(message: tr("Download started", "Download gestartet"))
                } label: {
                    Label(tr("Download", "Herunterladen"), systemImage: "arrow.down.circle")
                        .font(.subheadline).bold()
                        .foregroundStyle(accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            if isMarked {
                Button {
                    haptic()
                    for song in allSongs where downloadStore.isDownloaded(songId: song.id) {
                        downloadStore.deleteSong(song.id)
                    }
                    downloadStore.removeOfflinePlaylist(entry.playlistId)
                } label: {
                    Label(tr("Delete Downloads", "Downloads löschen"), systemImage: "arrow.down.circle")
                        .font(.subheadline).bold()
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let playlistSongs: [Song]
        if offlineMode.isOffline {
            guard let playlist = await libraryStore.loadPlaylistDetail(id: entry.playlistId) else {
                errorMessage = tr("Playlist could not be loaded.", "Playlist konnte nicht geladen werden.")
                return
            }
            playlistSongs = playlist.songs ?? []
        } else {
            do {
                let playlist = try await SubsonicAPIService.shared.getPlaylist(id: entry.playlistId)
                playlistSongs = playlist.songs ?? []
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let counts = await PlayLogService.shared.topSongs(
            serverId: serverId,
            from: Date(timeIntervalSince1970: entry.periodStart),
            to: Date(timeIntervalSince1970: entry.periodEnd),
            limit: period.type.songLimit
        )
        let countMap = Dictionary(uniqueKeysWithValues: counts.map { ($0.songId, $0.count) })

        songs = playlistSongs.map { song in
            SongWithCount(id: song.id, song: song, playCount: countMap[song.id] ?? 0)
        }
    }
}
